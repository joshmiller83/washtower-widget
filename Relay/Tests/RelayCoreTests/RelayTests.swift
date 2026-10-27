import Foundation
import Testing
@testable import RelayCore

/// The session state machine, driven by a fake ThinQ and a fake APNs.
@Suite struct RelayTests {
    let source = FakeLaundrySource()
    let sender = FakePushSender()
    let stateFile = StateFile(url: Fixture.temporaryDirectory().appending(path: "state.json"))
    let t0 = Fixture.t0

    func makeRelay() throws -> Relay {
        Relay(state: try stateFile.load(), stateFile: stateFile, source: source, sender: sender, composer: Fixture.composer())
    }

    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// Sets the laundry and polls once at `minutes` after t0.
    func poll(_ relay: Relay, _ minutes: Double, washer: String, washerLeft: Int? = nil,
              dryer: String = "POWER_OFF", dryerLeft: Int? = nil) async {
        await source.set(Fixture.snapshot(washer: washer, washerLeft: washerLeft, dryer: dryer, dryerLeft: dryerLeft, at: at(minutes)))
        await relay.tick(now: at(minutes))
    }

    @Test func fullCycle() async throws {
        let relay = try makeRelay()
        await relay.upsertDevice(id: "phone", name: "Josh's iPhone", pushToStartToken: Fixture.deviceToken, now: t0)

        // Idle: nothing happens.
        await poll(relay, 0, washer: "POWER_OFF")
        #expect(await sender.drain().isEmpty)
        #expect(await relay.state.session.active == false)

        // Washer starts: push-to-start to the phone.
        await poll(relay, 1, washer: "RUNNING", washerLeft: 50)
        var sent = await sender.drain()
        try #require(sent.count == 1)
        #expect(sent[0].token == Fixture.deviceToken)
        #expect(sent[0].push.event == .start)
        #expect(sent[0].push.alert?.title == "Washer started")
        #expect(await relay.state.session.active)

        // The phone registers the new activity: it gets the current state right away,
        // at priority 5 since nothing changed since the push-to-start.
        await relay.registerActivity(deviceId: "phone", activityId: "A1", pushToken: Fixture.activityToken, now: at(1.1))
        sent = await sender.drain()
        try #require(sent.count == 1)
        #expect(sent[0].token == Fixture.activityToken)
        #expect(sent[0].push.event == .update)
        #expect(sent[0].push.priority == 5)
        #expect(sent[0].push.alert == nil)

        // A minute later, one minute less to go: same finish time, so no push.
        await poll(relay, 2, washer: "RUNNING", washerLeft: 49)
        #expect(await sender.drain().isEmpty)

        // The finish time slips by 3 minutes: an update at priority 5.
        await poll(relay, 3, washer: "RUNNING", washerLeft: 51)
        sent = await sender.drain()
        try #require(sent.count == 1)
        #expect(sent[0].push.event == .update)
        #expect(sent[0].push.priority == 5)
        #expect(sent[0].push.alert == nil)

        // Drift under two minutes against what the phone shows: no push.
        await poll(relay, 4, washer: "RUNNING", washerLeft: 51)
        #expect(await sender.drain().isEmpty)

        // Rinsing: a new label, same phase.
        await poll(relay, 5, washer: "RINSING", washerLeft: 49)
        sent = await sender.drain()
        try #require(sent.count == 1)
        #expect(sent[0].push.state.drums[0].label == "Rinsing")
        #expect(sent[0].push.priority == 5)

        // Washer done while the dryer runs: an update with an alert, priority 10.
        await poll(relay, 54, washer: "END", dryer: "RUNNING", dryerLeft: 60)
        sent = await sender.drain()
        try #require(sent.count == 1)
        #expect(sent[0].push.event == .update)
        #expect(sent[0].push.priority == 10)
        #expect(sent[0].push.alert?.title == "Washer is done")
        #expect(sent[0].push.alert?.sound == "default")
        #expect(await relay.state.session.active)

        // Dryer done: the end, with its own alert, dismissed an hour later.
        await poll(relay, 115, washer: "POWER_OFF", dryer: "END")
        sent = await sender.drain()
        try #require(sent.count == 1)
        #expect(sent[0].push.event == .end)
        #expect(sent[0].push.alert?.title == "Dryer is done")
        #expect(sent[0].push.dismissalDate == Int(at(115).timeIntervalSince1970) + 3600)
        let session = await relay.state.session
        #expect(session.active == false)
        #expect(session.activities.isEmpty)

        // Still idle on the next poll.
        await poll(relay, 116, washer: "POWER_OFF", dryer: "END")
        #expect(await sender.drain().isEmpty)
    }

    @Test func restartMidCycleDoesNotStartAgain() async throws {
        let relay = try makeRelay()
        await relay.upsertDevice(id: "phone", name: "iPhone", pushToStartToken: Fixture.deviceToken, now: t0)
        await poll(relay, 0, washer: "RUNNING", washerLeft: 50)
        await relay.registerActivity(deviceId: "phone", activityId: "A1", pushToken: Fixture.activityToken, now: at(0.1))
        #expect(await sender.drain().count == 2)

        // A new process reads the same state file.
        let restarted = try makeRelay()
        await poll(restarted, 1, washer: "RUNNING", washerLeft: 49)
        #expect(await sender.drain().isEmpty)
        await poll(restarted, 2, washer: "END")
        let sent = await sender.drain()
        #expect(sent.map(\.push.event) == [.end])
        #expect(sent.first?.token == Fixture.activityToken)
    }

    @Test func goneTokensAreDropped() async throws {
        let otherPhone = String(repeating: "c3", count: 32)
        let relay = try makeRelay()
        await relay.upsertDevice(id: "phone", name: "iPhone", pushToStartToken: Fixture.deviceToken, now: t0)
        await relay.upsertDevice(id: "ipad", name: "iPad", pushToStartToken: otherPhone, now: t0)
        await sender.respond(to: Fixture.deviceToken, with: .badToken("Unregistered"))

        await poll(relay, 0, washer: "RUNNING", washerLeft: 50)
        #expect(await sender.drain().count == 2)
        var devices = await relay.state.devices
        #expect(devices["phone"]?.pushToStartToken == nil)
        #expect(devices["ipad"]?.pushToStartToken == otherPhone)

        // An activity token that comes back 410 leaves the session.
        await sender.respond(to: Fixture.activityToken, with: .badToken("Unregistered"))
        await relay.registerActivity(deviceId: "ipad", activityId: "A1", pushToken: Fixture.activityToken, now: at(0.1))
        #expect(await sender.drain().count == 1)
        #expect(await relay.state.session.activities.isEmpty)

        // Registering the device again without a token keeps the one it has.
        await relay.upsertDevice(id: "ipad", name: "iPad", pushToStartToken: nil, now: at(1))
        devices = await relay.state.devices
        #expect(devices["ipad"]?.pushToStartToken == otherPhone)
    }

    @Test func failedUpdateIsRetriedNextPoll() async throws {
        let relay = try makeRelay()
        await poll(relay, 0, washer: "RUNNING", washerLeft: 50)
        await sender.respond(to: Fixture.activityToken, with: .failed("APNs 500"))
        await relay.registerActivity(deviceId: "phone", activityId: "A1", pushToken: Fixture.activityToken, now: at(0.1))
        #expect(await sender.drain().count == 1)

        // Nothing changed, but the phone never got the state: try again.
        await sender.respond(to: Fixture.activityToken, with: .sent)
        await poll(relay, 1, washer: "RUNNING", washerLeft: 49)
        #expect(await sender.drain().count == 1)
        await poll(relay, 2, washer: "RUNNING", washerLeft: 48)
        #expect(await sender.drain().isEmpty)
        #expect(await relay.state.session.activities.first?.lastSent != nil)
    }

    @Test func refreshesBeforeContentGoesStale() async throws {
        let relay = try makeRelay()
        // Paused: no finish time, so the content goes stale an hour after each push.
        await poll(relay, 0, washer: "PAUSE", washerLeft: 30)
        await relay.registerActivity(deviceId: "phone", activityId: "A1", pushToken: Fixture.activityToken, now: at(0))
        #expect(await sender.drain().count == 1)
        await poll(relay, 30, washer: "PAUSE", washerLeft: 30)
        #expect(await sender.drain().isEmpty)
        await poll(relay, 56, washer: "PAUSE", washerLeft: 30)
        let sent = await sender.drain()
        #expect(sent.count == 1)
        #expect(sent.first?.push.priority == 5)
    }

    @Test func activitiesFromBetweenCyclesAreEndedAtTheNextStart() async throws {
        let relay = try makeRelay()
        await relay.upsertDevice(id: "phone", name: "iPhone", pushToStartToken: Fixture.deviceToken, now: t0)
        await poll(relay, 0, washer: "POWER_OFF")
        // e.g. the activity test-start made, registered while no cycle runs: stored, no push.
        await relay.registerActivity(deviceId: "phone", activityId: "T1", pushToken: Fixture.activityToken, now: at(1))
        #expect(await sender.drain().isEmpty)
        #expect(await relay.state.session.activities.count == 1)

        await poll(relay, 10, washer: "RUNNING", washerLeft: 50)
        let sent = await sender.drain()
        #expect(sent.map(\.push.event) == [.end, .start])
        #expect(sent[0].token == Fixture.activityToken)
        #expect(sent[0].push.dismissalDate == Int(at(10).timeIntervalSince1970))
        #expect(sent[1].token == Fixture.deviceToken)
        #expect(await relay.state.session.activities.isEmpty)
    }

    @Test func dismissedActivityGetsNoMorePushes() async throws {
        let relay = try makeRelay()
        await poll(relay, 0, washer: "RUNNING", washerLeft: 50)
        await relay.registerActivity(deviceId: "phone", activityId: "A1", pushToken: Fixture.activityToken, now: at(0))
        _ = await sender.drain()
        await relay.removeActivity(deviceId: "phone", activityId: "A1")
        await poll(relay, 1, washer: "RINSING", washerLeft: 40)
        await poll(relay, 2, washer: "END")
        #expect(await sender.drain().isEmpty)
    }

    @Test func thinqErrorKeepsTheSession() async throws {
        let relay = try makeRelay()
        await poll(relay, 0, washer: "RUNNING", washerLeft: 50)
        await relay.registerActivity(deviceId: "phone", activityId: "A1", pushToken: Fixture.activityToken, now: at(0))
        _ = await sender.drain()

        await source.fail(ThinQError.http(status: 503, code: nil, message: "busy"))
        await relay.tick(now: at(1))
        var state = await relay.state
        #expect(state.session.active)
        #expect(state.session.activities.count == 1)
        #expect(state.lastError?.contains("503") == true)
        #expect(state.lastState?.drums.first?.label == "Washing")
        #expect(await sender.drain().isEmpty)

        await poll(relay, 2, washer: "RUNNING", washerLeft: 48)
        state = await relay.state
        #expect(state.lastError == nil)
        #expect(state.session.active)
    }

    @Test func runsWithoutPush() async throws {
        let relay = Relay(state: RelayState(), stateFile: stateFile, source: source, sender: nil, composer: Fixture.composer())
        await relay.upsertDevice(id: "phone", name: "iPhone", pushToStartToken: Fixture.deviceToken, now: t0)
        await poll(relay, 0, washer: "RUNNING", washerLeft: 50)
        #expect(await relay.state.session.active)
        await relay.registerActivity(deviceId: "phone", activityId: "A1", pushToken: Fixture.activityToken, now: at(0))
        await poll(relay, 1, washer: "END")
        #expect(await relay.state.session.active == false)
    }

    @Test func stateFileIsPrivate() async throws {
        let relay = try makeRelay()
        await relay.upsertDevice(id: "phone", name: "iPhone", pushToStartToken: Fixture.deviceToken, now: t0)
        let attributes = try FileManager.default.attributesOfItem(atPath: stateFile.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try stateFile.load().devices["phone"]?.name == "iPhone")
    }
}
