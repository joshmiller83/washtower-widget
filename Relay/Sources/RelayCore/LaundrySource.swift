import Foundation

/// Where the relay's laundry state comes from: ThinQ in production, a fake in tests.
protocol LaundrySource: Sendable {
    func snapshot() async throws -> LaundrySnapshot
}

/// Reads the WashTower from ThinQ Connect. Caches the device list like the apps'
/// LaundryService: refreshed every 6 hours, or right away when a device 404s.
actor ThinQSource: LaundrySource {
    static let deviceListMaxAge: TimeInterval = 6 * 3600

    /// ThinQError.noToken talks about the apps' Settings; the relay reads a file.
    struct MissingToken: LocalizedError {
        var file: URL
        var errorDescription: String? { "No ThinQ token in \(file.path) (WT_THINQ_TOKEN_FILE)" }
    }

    private let tokenFile: URL
    private let country: String
    private let clientID: String
    private var devices: (list: [ThinQDevice], fetchedAt: Date)?

    init(tokenFile: URL, country: String, clientIDFile: URL) {
        self.tokenFile = tokenFile
        self.country = country
        clientID = Self.clientID(file: clientIDFile)
    }

    func snapshot() async throws -> LaundrySnapshot {
        // Read the token every time, so replacing the file needs no restart.
        guard let token = Files.readTrimmed(tokenFile) else { throw MissingToken(file: tokenFile) }
        let client = ThinQClient(token: token, countryCode: country, clientID: clientID)

        let list: [ThinQDevice]
        if let devices, Date().timeIntervalSince(devices.fetchedAt) < Self.deviceListMaxAge {
            list = devices.list
        } else {
            list = try await refreshDevices(client)
        }
        do {
            return try await client.snapshot(for: list)
        } catch ThinQError.http(404, _, _) {
            return try await client.snapshot(for: refreshDevices(client))
        }
    }

    private func refreshDevices(_ client: ThinQClient) async throws -> [ThinQDevice] {
        let list = try await client.devices()
        devices = (list, Date())
        let laundry = list.filter(\.isLaundry)
        Log.info("ThinQ devices: \(laundry.map { "\($0.alias.isEmpty ? $0.model : $0.alias) (\($0.type))" }.joined(separator: ", ")) — \(list.count - laundry.count) other(s) ignored")
        return list
    }

    /// A stable id for this install, kept next to the relay's state (LG asks clients
    /// not to make a new one per request).
    private static func clientID(file: URL) -> String {
        if let id = Files.readTrimmed(file) { return id }
        let id = "thinq-open-\(UUID().uuidString.lowercased())"
        do {
            try Files.writePrivate(Data((id + "\n").utf8), to: file)
        } catch {
            Log.warn("Couldn't save the ThinQ client id to \(file.path): \(error)")
        }
        return id
    }
}
