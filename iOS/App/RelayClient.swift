import Foundation
import Security

/// Where the relay is and the key it gave this phone. The key lives in the keychain,
/// readable after first unlock so a background wake from a push can still use it.
struct RelayConfig: Equatable, Sendable {
    var url: URL
    var key: String

    /// Parses `washtower://pair?url=https://…&key=…` from the relay's QR code.
    init?(pairingLink: URL) {
        guard pairingLink.scheme == "washtower", pairingLink.host() == "pair",
              let items = URLComponents(url: pairingLink, resolvingAgainstBaseURL: false)?.queryItems,
              let urlString = items.first(where: { $0.name == "url" })?.value,
              let url = URL(string: urlString), url.scheme == "https" || url.host() == "127.0.0.1",
              let key = items.first(where: { $0.name == "key" })?.value, key.count >= 32
        else { return nil }
        self.url = url
        self.key = key
    }

    init(url: URL, key: String) {
        self.url = url
        self.key = key
    }

    static func load() -> RelayConfig? {
        guard let string = UserDefaults.standard.string(forKey: "relayURL"), let url = URL(string: string),
              let key = Keychain.read(account: "relay-key") else { return nil }
        return RelayConfig(url: url, key: key)
    }

    func save() {
        UserDefaults.standard.set(url.absoluteString, forKey: "relayURL")
        Keychain.write(key, account: "relay-key")
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: "relayURL")
        Keychain.write(nil, account: "relay-key")
    }
}

struct RelayStateResponse: Decodable, Sendable {
    var state: LaundryActivityState?
    var error: String?
    var sessionActive: Bool
}

enum RelayError: LocalizedError {
    case unauthorized
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "The relay didn't accept this phone's key. Pair again."
        case .http(let status): "The relay answered with HTTP \(status)."
        }
    }
}

/// The relay's small JSON API (see Relay/ in the repo).
struct RelayClient: Sendable {
    var config: RelayConfig

    func state() async throws -> RelayStateResponse {
        try JSONDecoder().decode(RelayStateResponse.self, from: await send("GET", "v1/state"))
    }

    func registerDevice(id: String, name: String, pushToStartToken: Data?) async throws {
        var body: [String: String] = ["name": name]
        if let pushToStartToken { body["pushToStartToken"] = pushToStartToken.hex }
        _ = try await send("PUT", "v1/devices/\(id)", body: body)
    }

    func registerActivity(deviceID: String, activityID: String, pushToken: Data) async throws {
        _ = try await send("PUT", "v1/devices/\(deviceID)/activities/\(activityID)", body: ["pushToken": pushToken.hex])
    }

    func removeActivity(deviceID: String, activityID: String) async throws {
        _ = try await send("DELETE", "v1/devices/\(deviceID)/activities/\(activityID)")
    }

    private func send(_ method: String, _ path: String, body: [String: String]? = nil) async throws -> Data {
        var request = URLRequest(url: config.url.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw RelayError.unauthorized }
        guard (200..<300).contains(status) else { throw RelayError.http(status) }
        return data
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "WashTower",
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
