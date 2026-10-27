import Foundation

/// The phone-facing API. Everything except /v1/health needs `Authorization: Bearer <relay key>`.
///
///     GET    /v1/health                                   {"ok":true}
///     GET    /v1/state                                    {"state":…|null,"error":…|null,"sessionActive":Bool}
///     PUT    /v1/devices/{deviceId}                       {"name":String,"pushToStartToken":String?}
///     PUT    /v1/devices/{deviceId}/activities/{activity} {"pushToken":String}
///     DELETE /v1/devices/{deviceId}/activities/{activity}
struct RelayAPI: Sendable {
    let relay: Relay
    let key: String

    struct StateResponse: Encodable {
        var state: LaundryActivityState?
        var error: String?
        var sessionActive: Bool

        // Spelled out so nil comes through as null rather than a missing key.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state, forKey: .state)
            try container.encode(error, forKey: .error)
            try container.encode(sessionActive, forKey: .sessionActive)
        }

        enum CodingKeys: String, CodingKey {
            case state, error, sessionActive
        }
    }

    struct DeviceBody: Decodable {
        var name: String
        var pushToStartToken: String?
    }

    struct ActivityBody: Decodable {
        var pushToken: String
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let path = request.pathComponents
        if path == ["v1", "health"] {
            return request.method == "GET" ? .ok : .error(405, "method not allowed")
        }
        guard let token = request.bearerToken, RelayKey.matches(token, key: key) else {
            return .error(401, "unauthorized")
        }

        switch path.count {
        case 2 where path == ["v1", "state"]:
            guard request.method == "GET" else { return .error(405, "method not allowed") }
            let state = await relay.state
            return .json(StateResponse(state: state.lastState, error: state.lastError, sessionActive: state.session.active))

        case 3 where path[0] == "v1" && path[1] == "devices":
            guard request.method == "PUT" else { return .error(405, "method not allowed") }
            guard let deviceId = Self.validID(path[2]) else { return .error(400, "bad device id") }
            let body: DeviceBody
            do { body = try JSONDecoder().decode(DeviceBody.self, from: request.body) } catch {
                return .error(400, "expected {\"name\": String, \"pushToStartToken\": String?}")
            }
            let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 100 else { return .error(400, "bad name") }
            var token: String?
            if let raw = body.pushToStartToken {
                guard let normalized = Hex.normalizedToken(raw) else { return .error(400, "pushToStartToken must be hex") }
                token = normalized
            }
            await relay.upsertDevice(id: deviceId, name: name, pushToStartToken: token)
            return .ok

        case 5 where path[0] == "v1" && path[1] == "devices" && path[3] == "activities":
            guard let deviceId = Self.validID(path[2]), let activityId = Self.validID(path[4]) else {
                return .error(400, "bad device or activity id")
            }
            switch request.method {
            case "PUT":
                guard let body = try? JSONDecoder().decode(ActivityBody.self, from: request.body) else {
                    return .error(400, "expected {\"pushToken\": String}")
                }
                guard let token = Hex.normalizedToken(body.pushToken) else { return .error(400, "pushToken must be hex") }
                await relay.registerActivity(deviceId: deviceId, activityId: activityId, pushToken: token)
                return .ok
            case "DELETE":
                await relay.removeActivity(deviceId: deviceId, activityId: activityId)
                return .ok
            default:
                return .error(405, "method not allowed")
            }

        default:
            return .error(404, "not found")
        }
    }

    /// Ids are opaque, but keep them short and printable.
    static func validID(_ value: String) -> String? {
        guard (1...128).contains(value.count),
              value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F && $0 != "/" })
        else { return nil }
        return value
    }
}
