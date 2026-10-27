import CryptoKit
import Foundation
import Testing
@testable import RelayCore

@Suite struct PayloadTests {
    let composer = Fixture.composer()
    let now = Fixture.t0

    @Test func startPayloadShape() throws {
        let state = Fixture.state(washer: "RUNNING", washerLeft: 50, at: now)
        let push = composer.start(state, now: now)
        let aps = try #require(try Fixture.json(push.payload())["aps"] as? [String: Any])

        #expect(Set(aps.keys) == ["timestamp", "event", "content-state", "attributes-type", "attributes", "alert",
                                  "stale-date", "input-push-token"])
        #expect(aps["event"] as? String == "start")
        #expect(aps["timestamp"] as? Int == Int(now.timeIntervalSince1970))
        #expect(aps["attributes-type"] as? String == "LaundryActivityAttributes")
        #expect(aps["attributes"] as? [String: String] == ["title": "WashTower"])
        #expect(aps["input-push-token"] as? Int == 1)
        // 4:20 PM Central + 50 min; no sound on start.
        #expect(aps["alert"] as? [String: String] == ["title": "Washer started", "body": "Washing · done around 5:10 PM"])
        // Latest finish + 15 minutes.
        #expect(aps["stale-date"] as? Int == Int(now.timeIntervalSince1970) + 50 * 60 + 15 * 60)
        #expect(push.priority == 10)
        #expect(try decodedContentState(push) == state)
    }

    @Test func updatePayloadShape() throws {
        let old = Fixture.state(washer: "RUNNING", washerLeft: 50, at: now)
        let later = now.addingTimeInterval(600)
        let state = Fixture.state(washer: "RINSING", washerLeft: 35, at: later)
        let push = composer.update(state, since: old, now: later)
        let aps = try #require(try Fixture.json(push.payload())["aps"] as? [String: Any])

        #expect(Set(aps.keys) == ["timestamp", "event", "content-state", "stale-date"])
        #expect(aps["event"] as? String == "update")
        #expect(aps["timestamp"] as? Int == Int(later.timeIntervalSince1970))
        #expect(push.priority == 5)
        #expect(try decodedContentState(push) == state)
    }

    @Test func updateWithFinishedDrumAlerts() throws {
        let old = Fixture.state(washer: "RUNNING", washerLeft: 2, dryer: "RUNNING", dryerLeft: 40, at: now)
        let state = Fixture.state(washer: "END", dryer: "RUNNING", dryerLeft: 38, at: now.addingTimeInterval(120))
        let push = composer.update(state, since: old, now: now.addingTimeInterval(120))
        let aps = try #require(try Fixture.json(push.payload())["aps"] as? [String: Any])

        #expect(aps["alert"] as? [String: String] == ["title": "Washer is done", "body": "Finished at 4:22 PM", "sound": "default"])
        #expect(push.priority == 10)
    }

    @Test func endPayloadShape() throws {
        let old = Fixture.state(washer: "POWER_OFF", dryer: "RUNNING", dryerLeft: 1, at: now)
        let later = now.addingTimeInterval(120)
        let state = Fixture.state(washer: "POWER_OFF", dryer: "END", at: later)
        let push = composer.end(state, since: old, now: later)
        let aps = try #require(try Fixture.json(push.payload())["aps"] as? [String: Any])

        #expect(Set(aps.keys) == ["timestamp", "event", "content-state", "dismissal-date", "alert"])
        #expect(aps["event"] as? String == "end")
        #expect(aps["dismissal-date"] as? Int == Int(later.timeIntervalSince1970) + 3600)
        #expect((aps["alert"] as? [String: String])?["title"] == "Dryer is done")
        #expect(try decodedContentState(push) == state)
    }

    @Test func endWithoutFinishHasNoAlert() throws {
        let old = Fixture.state(washer: "RUNNING", washerLeft: 20, at: now)
        let state = Fixture.state(washer: "POWER_OFF", at: now)
        let aps = try #require(try Fixture.json(composer.end(state, since: old, now: now).payload())["aps"] as? [String: Any])
        #expect(aps["alert"] == nil)
    }

    /// content-state is LaundryActivityState's own encoding: same keys, nothing renamed.
    @Test func contentStateKeepsFieldNames() throws {
        let state = Fixture.state(washer: "RUNNING", washerLeft: 50, at: now)
        let aps = try #require(try Fixture.json(composer.start(state, now: now).payload())["aps"] as? [String: Any])
        let contentState = try #require(aps["content-state"] as? [String: Any])
        #expect(Set(contentState.keys) == ["drums", "updatedAt"])
        let washer = try #require((contentState["drums"] as? [[String: Any]])?.first)
        #expect(Set(washer.keys) == ["id", "kind", "name", "phase", "label", "startedAt", "endsAt"])
        #expect(washer["phase"] as? String == "running")

        let direct = try Fixture.json(JSONEncoder().encode(state))
        #expect(NSDictionary(dictionary: direct).isEqual(to: contentState))
    }

    @Test func multipleDrumsStartAlert() {
        let state = Fixture.state(washer: "RUNNING", washerLeft: 30, dryer: "RUNNING", dryerLeft: 60, at: now)
        let alert = composer.startAlert(state)
        #expect(alert.title == "Washer and Dryer started")
        #expect(alert.body == "Washer: Washing · done around 4:50 PM\nDryer: Drying · done around 5:20 PM")
        #expect(alert.sound == nil)
    }

    @Test func staleDateWithoutTimer() {
        let state = Fixture.state(washer: "PAUSE", washerLeft: 30, at: now)
        #expect(PushComposer.staleDate(for: state, now: now) == Int(now.timeIntervalSince1970) + 3600)
    }

    @Test func priorities() {
        let running = Fixture.state(washer: "RUNNING", washerLeft: 30, at: now)
        let drifted = Fixture.state(washer: "RUNNING", washerLeft: 34, at: now)
        let paused = Fixture.state(washer: "PAUSE", washerLeft: 30, at: now)
        #expect(PushComposer.priority(for: drifted, since: running) == 5)
        #expect(PushComposer.priority(for: paused, since: running) == 10)
        #expect(PushComposer.priority(for: running, since: nil) == 10)
    }

    // MARK: APNs request

    @Test func apnsRequestHeadersAndSignedJWT() async throws {
        let directory = Fixture.temporaryDirectory()
        let privateKey = P256.Signing.PrivateKey()
        let keyFile = directory.appending(path: "AuthKey_TEST.p8")
        try Data(privateKey.pemRepresentation.utf8).write(to: keyFile)
        let config = APNsConfig(keyFile: keyFile, keyID: "KEY1234567", teamID: "TEAM123456",
                                bundleID: "com.example.WashTower", environment: .development)
        let sender = try APNsSender(config: config)
        let push = composer.start(Fixture.state(washer: "RUNNING", washerLeft: 50, at: now), now: now)

        let request = try await sender.request(for: push, to: Fixture.deviceToken, now: now)
        #expect(request.url?.absoluteString == "https://api.sandbox.push.apple.com/3/device/\(Fixture.deviceToken)")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apns-push-type") == "liveactivity")
        #expect(request.value(forHTTPHeaderField: "apns-topic") == "com.example.WashTower.push-type.liveactivity")
        #expect(request.value(forHTTPHeaderField: "apns-priority") == "10")
        #expect(request.httpBody == (try push.payload()))

        let authorization = try #require(request.value(forHTTPHeaderField: "authorization"))
        #expect(authorization.hasPrefix("bearer "))
        let parts = authorization.dropFirst("bearer ".count).split(separator: ".").map(String.init)
        try #require(parts.count == 3)
        #expect(try base64urlJSON(parts[0]) == ["alg": "ES256", "kid": "KEY1234567"] as NSDictionary)
        #expect(try base64urlJSON(parts[1]) == ["iss": "TEAM123456", "iat": Int(now.timeIntervalSince1970)] as NSDictionary)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: base64url(parts[2]))
        #expect(privateKey.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))

        // Reused within 50 minutes, renewed after.
        #expect(try await sender.jwt(now: now.addingTimeInterval(49 * 60)) == String(authorization.dropFirst(7)))
        #expect(try await sender.jwt(now: now.addingTimeInterval(51 * 60)) != String(authorization.dropFirst(7)))
    }

    @Test func productionHost() {
        #expect(APNsEnvironment.production.host.absoluteString == "https://api.push.apple.com")
    }

    @Test func apnsOutcomes() {
        func body(_ reason: String) -> Data { Data(#"{"reason":"\#(reason)"}"#.utf8) }
        #expect(APNsSender.outcome(status: 200, body: Data()) == .sent)
        #expect(APNsSender.outcome(status: 410, body: body("Unregistered")) == .badToken("Unregistered"))
        #expect(APNsSender.outcome(status: 410, body: body("ExpiredToken")) == .badToken("ExpiredToken"))
        #expect(APNsSender.outcome(status: 400, body: body("BadDeviceToken")) == .badToken("BadDeviceToken"))
        #expect(APNsSender.outcome(status: 400, body: body("ExpiredToken")) == .badToken("ExpiredToken"))
        #expect(APNsSender.outcome(status: 400, body: body("BadPriority")) == .failed("APNs 400 BadPriority"))
        #expect(APNsSender.outcome(status: 403, body: body("InvalidProviderToken")) == .failed("APNs 403 InvalidProviderToken"))
        #expect(APNsSender.outcome(status: 429, body: Data()) == .failed("APNs 429 "))
    }

    // MARK: Helpers

    private func decodedContentState(_ push: LiveActivityPush) throws -> LaundryActivityState {
        let aps = try #require(try Fixture.json(push.payload())["aps"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: try #require(aps["content-state"]))
        return try JSONDecoder().decode(LaundryActivityState.self, from: data)
    }

    private func base64url(_ text: String) throws -> Data {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return try #require(Data(base64Encoded: base64))
    }

    private func base64urlJSON(_ text: String) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: base64url(text)) as? NSDictionary)
    }
}
