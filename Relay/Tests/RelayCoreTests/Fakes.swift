import Foundation
import Testing
@testable import RelayCore

/// Laundry state the test sets before each tick.
actor FakeLaundrySource: LaundrySource {
    private var next: Result<LaundrySnapshot, any Error> = .failure(ThinQError.noToken)

    func set(_ snapshot: LaundrySnapshot) { next = .success(snapshot) }
    func fail(_ error: any Error) { next = .failure(error) }

    func snapshot() async throws -> LaundrySnapshot { try next.get() }
}

/// Records pushes; answers with a scripted outcome per token (default: sent).
actor FakePushSender: LiveActivityPushSender {
    struct Sent: Sendable {
        var push: LiveActivityPush
        var token: String
    }

    private(set) var sent: [Sent] = []
    private var outcomes: [String: PushOutcome] = [:]

    func respond(to token: String, with outcome: PushOutcome) { outcomes[token] = outcome }

    func send(_ push: LiveActivityPush, to token: String) async -> PushOutcome {
        sent.append(Sent(push: push, token: token))
        return outcomes[token] ?? .sent
    }

    /// Everything sent so far, and forget it.
    func drain() -> [Sent] {
        defer { sent = [] }
        return sent
    }
}

enum Fixture {
    static let t0 = Date(timeIntervalSince1970: 1_761_600_000)  // 2025-10-27 21:20 UTC
    static let central = TimeZone(identifier: "America/Chicago")!
    static let deviceToken = String(repeating: "a1", count: 32)
    static let activityToken = String(repeating: "b2", count: 32)

    static func drum(_ kind: DrumKind, _ state: String, remaining: Int? = nil, total: Int? = nil, at: Date) -> DrumStatus {
        DrumStatus(
            id: "wt:\(kind.rawValue)", kind: kind, name: kind.defaultName, state: state,
            remainingMinutes: remaining, totalMinutes: total ?? remaining, startsInMinutes: nil, fetchedAt: at)
    }

    static func snapshot(washer: String, washerLeft: Int? = nil, dryer: String = "POWER_OFF", dryerLeft: Int? = nil,
                         at: Date) -> LaundrySnapshot {
        LaundrySnapshot(drums: [
            drum(.washer, washer, remaining: washerLeft, total: washerLeft.map { _ in 60 }, at: at),
            drum(.dryer, dryer, remaining: dryerLeft, total: dryerLeft.map { _ in 70 }, at: at),
        ], fetchedAt: at)
    }

    static func state(washer: String, washerLeft: Int? = nil, dryer: String = "POWER_OFF", dryerLeft: Int? = nil,
                      at: Date) -> LaundryActivityState {
        LaundryActivityState(snapshot: snapshot(washer: washer, washerLeft: washerLeft, dryer: dryer, dryerLeft: dryerLeft, at: at))
    }

    static func temporaryDirectory() -> URL {
        Log.mute()
        let url = FileManager.default.temporaryDirectory.appending(path: "washtower-relay-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func composer() -> PushComposer {
        Log.mute()
        return PushComposer(timeZone: central, dismissAfter: 3600)
    }

    static func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
