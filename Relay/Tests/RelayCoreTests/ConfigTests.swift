import Foundation
import Testing
@testable import RelayCore

@Suite struct ConfigTests {
    @Test func defaults() {
        let config = RelayConfig.fromEnvironment(["HOME": NSHomeDirectory()])
        #expect(config.dataDir.path == NSHomeDirectory() + "/WashTowerRelay")
        #expect(config.host == "127.0.0.1")
        #expect(config.port == 8792)
        #expect(config.thinqTokenFile.path == NSHomeDirectory() + "/.config/thinq/pat")
        #expect(config.country == "US")
        #expect(config.dismissAfterMinutes == 60)
        #expect(config.apns == nil)
        #expect(config.apnsProblem == "WT_APNS_KEY_FILE, WT_APNS_KEY_ID, WT_APNS_TEAM_ID not set")
    }

    @Test func apnsFromEnvironment() throws {
        let config = RelayConfig.fromEnvironment([
            "WT_DATA_DIR": "/tmp/wt", "WT_PORT": "9000", "WT_COUNTRY": "ca", "WT_DISMISS_AFTER_MINUTES": "15",
            "WT_APNS_KEY_FILE": "/keys/AuthKey.p8", "WT_APNS_KEY_ID": "KEY", "WT_APNS_TEAM_ID": "TEAM",
            "WT_APNS_ENV": "production",
        ])
        #expect(config.dataDir.path == "/tmp/wt")
        #expect(config.port == 9000)
        #expect(config.country == "CA")
        #expect(config.dismissAfterMinutes == 15)
        let apns = try #require(config.apns)
        #expect(apns.environment == .production)
        #expect(apns.bundleID == "com.joshmiller83.WashTower")
        #expect(apns.topic == "com.joshmiller83.WashTower.push-type.liveactivity")
        #expect(apns.keyFile.path == "/keys/AuthKey.p8")
    }

    @Test func partialAPNsSettingsDisablePush() {
        let config = RelayConfig.fromEnvironment(["WT_APNS_KEY_FILE": "/k.p8", "WT_APNS_KEY_ID": "", "WT_APNS_TEAM_ID": "T"])
        #expect(config.apns == nil)
        #expect(config.apnsProblem == "WT_APNS_KEY_ID not set")
        let badEnv = RelayConfig.fromEnvironment([
            "WT_APNS_KEY_FILE": "/k.p8", "WT_APNS_KEY_ID": "K", "WT_APNS_TEAM_ID": "T", "WT_APNS_ENV": "staging",
        ])
        #expect(badEnv.apns == nil)
    }
}

@Suite struct RelayKeyTests {
    @Test func makesAPrivateKeyOnce() throws {
        let url = Fixture.temporaryDirectory().appending(path: "sub/relay-key")
        let first = try RelayKey.ensure(at: url)
        #expect(first.created)
        #expect(first.key.count == 64)
        #expect(Hex.normalizedToken(first.key) == first.key)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let second = try RelayKey.ensure(at: url)
        #expect(!second.created)
        #expect(second.key == first.key)
    }

    @Test func rejectsAMangledKeyFile() throws {
        let url = Fixture.temporaryDirectory().appending(path: "relay-key")
        try Data("short".utf8).write(to: url)
        #expect(throws: RelayKey.Problem.self) { try RelayKey.ensure(at: url) }
    }

    @Test func pairLink() {
        let key = String(repeating: "ab", count: 32)
        #expect(RelayKey.pairLink(url: "https://washtower.example.com", key: key)
            == "washtower://pair?url=https%3A%2F%2Fwashtower.example.com&key=\(key)")
    }

    @Test func keyComparison() {
        #expect(RelayKey.matches("abc", key: "abc"))
        #expect(!RelayKey.matches("abd", key: "abc"))
        #expect(!RelayKey.matches("ab", key: "abc"))
        #expect(!RelayKey.matches("abcd", key: "abc"))
        #expect(!RelayKey.matches("", key: "abc"))
    }
}
