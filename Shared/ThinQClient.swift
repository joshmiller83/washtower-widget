import Foundation

struct ThinQDevice: Codable, Sendable, Hashable {
    var id: String
    var type: String
    var alias: String
    var model: String

    var isLaundry: Bool {
        let type = type.uppercased()
        return (type.contains("WASH") || type.contains("DRYER")) && !type.contains("DISH")
    }
}

enum ThinQError: LocalizedError, Sendable {
    case noToken
    case unsupportedCountry(String)
    case http(status: Int, code: String?, message: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noToken:
            "Add your ThinQ personal access token in Settings."
        case .unsupportedCountry(let code):
            "ThinQ Connect doesn't support country code \u{201C}\(code)\u{201D}."
        case .http(let status, _, let message) where status == 401 || status == 403:
            "ThinQ rejected the token (\(message ?? "HTTP \(status)")). Check it in Settings."
        case .http(let status, let code, let message):
            "ThinQ error \(status)\(code.map { " (\($0))" } ?? ""): \(message ?? "no details")"
        case .invalidResponse:
            "ThinQ sent a response this app doesn't understand."
        }
    }
}

/// Minimal client for LG's official ThinQ Connect API, authenticated with a
/// personal access token (https://connect-pat.lgthinq.com).
struct ThinQClient: Sendable {
    /// Public client key shipped in LG's own SDK; every ThinQ Connect client sends it.
    static let apiKey = "v6GFvkweNo7DK7yD3ylIZ9w52aKBU0eJ7wLXkSR3"

    var token: String
    var countryCode: String
    /// Stable per-install id (LG asks clients not to generate a new one per request).
    var clientID: String

    func devices() async throws -> [ThinQDevice] {
        let list = try await get("devices") as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let id = entry["deviceId"] as? String,
                  let info = entry["deviceInfo"] as? [String: Any] else { return nil }
            return ThinQDevice(
                id: id,
                type: info["deviceType"] as? String ?? "",
                alias: info["alias"] as? String ?? "",
                model: info["modelName"] as? String ?? ""
            )
        }
    }

    func snapshot(for devices: [ThinQDevice]) async throws -> LaundrySnapshot {
        let now = Date()
        var drums: [DrumStatus] = []
        for device in devices where device.isLaundry {
            let state = try await get("devices/\(device.id)/state")
            drums += ThinQParser.drums(deviceID: device.id, deviceType: device.type, state: state, fetchedAt: now)
        }
        drums.sort { ($0.kind.sortOrder, $0.name) < ($1.kind.sortOrder, $1.name) }
        return LaundrySnapshot(drums: drums, fetchedAt: now)
    }

    /// Returns the `response` member of a successful reply.
    private func get(_ path: String) async throws -> Any? {
        guard let region = ThinQRegion.forCountry(countryCode) else {
            throw ThinQError.unsupportedCountry(countryCode)
        }
        var request = URLRequest(url: region.baseURL.appending(path: path))
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(countryCode.uppercased(), forHTTPHeaderField: "x-country")
        request.setValue(Self.messageID(), forHTTPHeaderField: "x-message-id")
        request.setValue(clientID, forHTTPHeaderField: "x-client-id")
        request.setValue(Self.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("OP", forHTTPHeaderField: "x-service-phase")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = json?["error"] as? [String: Any]
            throw ThinQError.http(status: status, code: error?["code"] as? String, message: error?["message"] as? String)
        }
        guard let json else { throw ThinQError.invalidResponse }
        return json["response"]
    }

    /// base64url of a random UUID without padding, matching LG's SDK.
    private static func messageID() -> String {
        let bytes = withUnsafeBytes(of: UUID().uuid) { Data($0) }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
