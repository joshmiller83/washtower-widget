import CryptoKit
import Foundation

/// Sends Live Activity pushes to APNs over HTTP/2 (URLSession negotiates it), signed
/// with a provider token: an ES256 JWT from the .p8 key, renewed every 50 minutes.
actor APNsSender: LiveActivityPushSender {
    enum SetupError: LocalizedError {
        case unreadableKey(URL, String)

        var errorDescription: String? {
            switch self {
            case .unreadableKey(let url, let reason): "Couldn't load the APNs key at \(url.path): \(reason)"
            }
        }
    }

    let config: APNsConfig
    private let key: P256.Signing.PrivateKey
    private let session: URLSession
    private var token: (value: String, madeAt: Date)?

    init(config: APNsConfig) throws {
        let pem: String
        do {
            pem = try String(contentsOf: config.keyFile, encoding: .utf8)
        } catch {
            throw SetupError.unreadableKey(config.keyFile, error.localizedDescription)
        }
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw SetupError.unreadableKey(config.keyFile, "not a P-256 private key in PEM form (\(error))")
        }
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    func send(_ push: LiveActivityPush, to deviceToken: String) async -> PushOutcome {
        do {
            let request = try request(for: push, to: deviceToken, now: Date())
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let outcome = Self.outcome(status: status, body: data)
            if case .failed(let reason) = outcome, reason.contains("ExpiredProviderToken") {
                token = nil
            }
            return outcome
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// POST {host}/3/device/{token}, with the provider token and Live Activity headers.
    func request(for push: LiveActivityPush, to deviceToken: String, now: Date) throws -> URLRequest {
        var request = URLRequest(url: config.environment.host.appending(path: "3/device/\(deviceToken)"))
        request.httpMethod = "POST"
        request.httpBody = try push.payload()
        request.setValue("bearer " + (try jwt(now: now)), forHTTPHeaderField: "authorization")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue(config.topic, forHTTPHeaderField: "apns-topic")
        request.setValue(String(push.priority), forHTTPHeaderField: "apns-priority")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    /// 200 is sent; 410, and 400 BadDeviceToken/ExpiredToken mean the token is dead.
    /// (A sandbox token sent to production, or the reverse, also comes back as
    /// BadDeviceToken: check WT_APNS_ENV if every token gets dropped.)
    static func outcome(status: Int, body: Data) -> PushOutcome {
        let reason = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["reason"] as? String
        switch status {
        case 200:
            return .sent
        case 410:
            return .badToken(reason ?? "Unregistered")
        case 400 where reason == "BadDeviceToken" || reason == "ExpiredToken":
            return .badToken(reason ?? "")
        default:
            return .failed("APNs \(status) \(reason ?? String(decoding: body.prefix(200), as: UTF8.self))")
        }
    }

    /// The provider token, reused for 50 minutes (APNs rejects tokens older than an
    /// hour, and renewing more often than every 20 minutes).
    func jwt(now: Date) throws -> String {
        if let token, now.timeIntervalSince(token.madeAt) < 50 * 60 { return token.value }
        let header = Self.base64url(Data(#"{"alg":"ES256","kid":"\#(config.keyID)"}"#.utf8))
        let claims = Self.base64url(Data(#"{"iss":"\#(config.teamID)","iat":\#(Int(now.timeIntervalSince1970))}"#.utf8))
        let signature = try key.signature(for: Data((header + "." + claims).utf8))
        let value = header + "." + claims + "." + Self.base64url(signature.rawRepresentation)
        token = (value, now)
        return value
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
