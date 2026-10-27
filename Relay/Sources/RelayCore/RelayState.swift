import Foundation

/// A phone that registered with the relay.
struct RelayDevice: Codable, Equatable, Sendable {
    var name: String
    /// ActivityKit's push-to-start token (hex). The relay starts the Live Activity with it.
    var pushToStartToken: String?
    var updatedAt: Date
}

/// One Live Activity on one phone, with the token that updates and ends it.
struct ActivityRegistration: Codable, Equatable, Sendable {
    var deviceId: String
    var activityId: String
    var pushToken: String
    var registeredAt: Date
    /// What this activity was last sent (nil until a push to it succeeds), and when
    /// that content goes stale (Unix seconds).
    var lastSent: LaundryActivityState?
    var staleAt: Double?
}

/// One laundry cycle, from the push-to-start to the end push.
struct RelaySession: Codable, Equatable, Sendable {
    var active = false
    var startedAt: Date?
    /// The state the session last pushed (the push-to-start's, then each visible change).
    var lastSent: LaundryActivityState?
    /// Activities to update and end. While no session is active, this holds activities
    /// the phone registered in between (a late token, a test-start); the next start ends them.
    var activities: [ActivityRegistration] = []
}

/// Everything the relay remembers across restarts: $WT_DATA_DIR/state.json.
struct RelayState: Codable, Equatable, Sendable {
    var devices: [String: RelayDevice] = [:]
    var session = RelaySession()
    /// The last state read from ThinQ, and the last ThinQ error (cleared by a good poll).
    var lastState: LaundryActivityState?
    var lastError: String?
    var lastPollAt: Date?
}

/// Loads and saves the state file. Writes are atomic and mode 600 (it holds push tokens).
struct StateFile: Sendable {
    var url: URL

    func load() throws -> RelayState {
        guard FileManager.default.fileExists(atPath: url.path) else { return RelayState() }
        return try Self.decoder.decode(RelayState.self, from: Data(contentsOf: url))
    }

    /// Like `load`, but a corrupt file is moved aside (and logged) instead of stopping the relay.
    func loadOrReset() -> RelayState {
        do {
            return try load()
        } catch {
            let aside = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: aside)
            Log.error("Couldn't read \(url.path) (\(error)); moved it to \(aside.lastPathComponent) and starting fresh")
            return RelayState()
        }
    }

    func save(_ state: RelayState) throws {
        try Files.writePrivate(Self.encoder.encode(state), to: url)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
