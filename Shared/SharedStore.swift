import Foundation

/// Settings and cached state shared by the app and the widget through their App Group container.
enum SharedStore {
    /// "<TEAM_ID>.<bundle prefix>.washtower", injected into both Info.plists at build time.
    static let groupID = Bundle.main.object(forInfoDictionaryKey: "WTAppGroupID") as? String ?? ""

    private static var defaults: UserDefaults { UserDefaults(suiteName: groupID) ?? .standard }

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    private static func file(_ name: String) -> URL? { container?.appending(path: name) }

    // MARK: Settings

    /// Kept in a 0600 file in the group container rather than the keychain: sharing a
    /// keychain item between an app and its widget on macOS needs a provisioning
    /// profile, which would tie the build to one Mac.
    static var token: String? {
        get {
            guard let url = file("thinq-token"),
                  let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }
        set {
            guard let url = file("thinq-token") else { return }
            if let newValue, !newValue.isEmpty {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(newValue.utf8).write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static var countryCode: String {
        get { defaults.string(forKey: "countryCode") ?? Locale.current.region?.identifier ?? "US" }
        set { defaults.set(newValue.uppercased(), forKey: "countryCode") }
    }

    static var clientID: String {
        if let id = defaults.string(forKey: "clientID") { return id }
        let id = "thinq-open-\(UUID().uuidString.lowercased())"
        defaults.set(id, forKey: "clientID")
        return id
    }

    // MARK: Cached state

    static var snapshot: LaundrySnapshot? {
        get { read(LaundrySnapshot.self, from: "snapshot.json") }
        set { write(newValue, to: "snapshot.json") }
    }

    private struct DeviceCache: Codable {
        var devices: [ThinQDevice]
        var fetchedAt: Date
    }

    static func cachedDevices(maxAge: TimeInterval) -> [ThinQDevice]? {
        guard let cache = read(DeviceCache.self, from: "devices.json"),
              Date().timeIntervalSince(cache.fetchedAt) < maxAge else { return nil }
        return cache.devices
    }

    static func cacheDevices(_ devices: [ThinQDevice]) {
        write(DeviceCache(devices: devices, fetchedAt: Date()), to: "devices.json")
    }

    /// Call after the token or country changes, since cached devices may belong to another account.
    static func clearCaches() {
        write(DeviceCache?.none, to: "devices.json")
        snapshot = nil
    }

    private static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let url = file(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T?, to name: String) {
        guard let url = file(name) else { return }
        guard let value, let data = try? JSONEncoder().encode(value) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}

/// The one place that talks to ThinQ, used by both the app's poller and the widget.
enum LaundryService {
    /// Fetches fresh state and saves it for the other process. Refreshes the device
    /// list every few hours, or right away if a device has disappeared.
    static func refresh() async throws -> LaundrySnapshot {
        guard let token = SharedStore.token else { throw ThinQError.noToken }
        let client = ThinQClient(token: token, countryCode: SharedStore.countryCode, clientID: SharedStore.clientID)

        var devices: [ThinQDevice]
        if let cached = SharedStore.cachedDevices(maxAge: 6 * 3600) {
            devices = cached
        } else {
            devices = try await client.devices()
            SharedStore.cacheDevices(devices)
        }

        let snapshot: LaundrySnapshot
        do {
            snapshot = try await client.snapshot(for: devices)
        } catch ThinQError.http(404, _, _) {
            devices = try await client.devices()
            SharedStore.cacheDevices(devices)
            snapshot = try await client.snapshot(for: devices)
        }
        SharedStore.snapshot = snapshot
        return snapshot
    }

    /// The saved snapshot if it's newer than `maxAge`, otherwise a fresh fetch.
    /// Falls back to the saved snapshot (with the error) when the fetch fails.
    static func current(maxAge: TimeInterval) async -> (snapshot: LaundrySnapshot?, error: String?) {
        let saved = SharedStore.snapshot
        if let saved, Date().timeIntervalSince(saved.fetchedAt) < maxAge {
            return (saved, nil)
        }
        do {
            return (try await refresh(), nil)
        } catch {
            return (saved, error.localizedDescription)
        }
    }
}
