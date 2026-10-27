import Foundation

/// The relay's settings, read from WT_* environment variables (the launchd plist sets them).
struct RelayConfig: Sendable {
    var dataDir: URL
    var host: String
    var port: UInt16
    var thinqTokenFile: URL
    var country: String
    /// Nil when push isn't set up; `apnsProblem` says why.
    var apns: APNsConfig?
    var apnsProblem: String?
    var dismissAfterMinutes: Int
    var pollInterval: Duration = .seconds(60)

    var stateFile: URL { dataDir.appending(path: "state.json") }
    var relayKeyFile: URL { dataDir.appending(path: "relay-key") }
    var thinqClientIDFile: URL { dataDir.appending(path: "thinq-client-id") }

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> RelayConfig {
        func value(_ name: String) -> String? {
            guard let raw = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
        func path(_ name: String, default fallback: String) -> URL {
            URL(fileURLWithPath: NSString(string: value(name) ?? fallback).expandingTildeInPath)
        }

        var config = RelayConfig(
            dataDir: path("WT_DATA_DIR", default: "~/WashTowerRelay"),
            host: value("WT_HOST") ?? "127.0.0.1",
            port: value("WT_PORT").flatMap(UInt16.init) ?? 8792,
            thinqTokenFile: path("WT_THINQ_TOKEN_FILE", default: "~/.config/thinq/pat"),
            country: (value("WT_COUNTRY") ?? "US").uppercased(),
            apns: nil,
            apnsProblem: nil,
            dismissAfterMinutes: max(0, value("WT_DISMISS_AFTER_MINUTES").flatMap(Int.init) ?? 60)
        )

        let keyFile = value("WT_APNS_KEY_FILE")
        let keyID = value("WT_APNS_KEY_ID")
        let teamID = value("WT_APNS_TEAM_ID")
        let missing = [("WT_APNS_KEY_FILE", keyFile), ("WT_APNS_KEY_ID", keyID), ("WT_APNS_TEAM_ID", teamID)]
            .filter { $0.1 == nil }.map(\.0)
        let environment = APNsEnvironment(setting: value("WT_APNS_ENV") ?? "development")
        if !missing.isEmpty {
            config.apnsProblem = "\(missing.joined(separator: ", ")) not set"
        } else if environment == nil {
            config.apnsProblem = "WT_APNS_ENV must be \"development\" or \"production\""
        } else if let keyFile, let keyID, let teamID, let environment {
            config.apns = APNsConfig(
                keyFile: URL(fileURLWithPath: NSString(string: keyFile).expandingTildeInPath),
                keyID: keyID,
                teamID: teamID,
                bundleID: value("WT_APNS_BUNDLE_ID") ?? "com.joshmiller83.WashTower",
                environment: environment
            )
        }
        return config
    }
}

enum APNsEnvironment: String, Sendable {
    /// Builds installed from Xcode.
    case development
    /// TestFlight and App Store builds.
    case production

    init?(setting: String) {
        switch setting.lowercased() {
        case "development", "sandbox": self = .development
        case "production": self = .production
        default: return nil
        }
    }

    var host: URL {
        switch self {
        case .development: URL(string: "https://api.sandbox.push.apple.com")!
        case .production: URL(string: "https://api.push.apple.com")!
        }
    }
}

struct APNsConfig: Sendable {
    /// The .p8 auth key from developer.apple.com > Keys.
    var keyFile: URL
    var keyID: String
    var teamID: String
    var bundleID: String
    var environment: APNsEnvironment

    /// Live Activity pushes go to the app's topic with this suffix.
    var topic: String { bundleID + ".push-type.liveactivity" }
}
