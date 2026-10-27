import Foundation

/// One ActivityKit push: what APNs gets in the body, plus the priority header.
struct LiveActivityPush: Equatable, Sendable {
    enum Event: String, Sendable {
        case start, update, end
    }

    struct Alert: Codable, Equatable, Sendable {
        var title: String
        var body: String
        var sound: String?
    }

    /// The Swift type name of the app's ActivityAttributes, and its static attributes.
    static let attributesType = "LaundryActivityAttributes"
    static let attributesTitle = "WashTower"

    var event: Event
    var state: LaundryActivityState
    /// Unix seconds; ActivityKit ignores pushes older than what it already shows.
    var timestamp: Int
    var alert: Alert?
    var staleDate: Int?
    var dismissalDate: Int?
    /// apns-priority: 10 sends now, 5 lets the system pick a moment (and spares the budget).
    var priority: Int

    /// The JSON body. content-state is LaundryActivityState encoded by a plain
    /// JSONEncoder, so its field names reach ActivityKit unchanged.
    func payload() throws -> Data {
        let aps = APS(
            timestamp: timestamp,
            event: event.rawValue,
            contentState: state,
            attributesType: event == .start ? Self.attributesType : nil,
            attributes: event == .start ? Attributes(title: Self.attributesTitle) : nil,
            alert: alert,
            staleDate: staleDate,
            dismissalDate: dismissalDate,
            inputPushToken: event == .start ? 1 : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Body(aps: aps))
    }

    private struct Body: Encodable {
        var aps: APS
    }

    private struct Attributes: Encodable {
        var title: String
    }

    private struct APS: Encodable {
        var timestamp: Int
        var event: String
        var contentState: LaundryActivityState
        var attributesType: String?
        var attributes: Attributes?
        var alert: Alert?
        var staleDate: Int?
        var dismissalDate: Int?
        var inputPushToken: Int?

        enum CodingKeys: String, CodingKey {
            case timestamp, event, attributes, alert
            case contentState = "content-state"
            case attributesType = "attributes-type"
            case staleDate = "stale-date"
            case dismissalDate = "dismissal-date"
            case inputPushToken = "input-push-token"
        }
    }
}

/// Builds start, update and end pushes, with their alerts and dates.
struct PushComposer: Sendable {
    var timeZone: TimeZone = .current
    /// How long an ended activity stays on the Lock Screen.
    var dismissAfter: TimeInterval = 3600

    func start(_ state: LaundryActivityState, now: Date) -> LiveActivityPush {
        LiveActivityPush(
            event: .start, state: state, timestamp: Self.seconds(now), alert: startAlert(state),
            staleDate: Self.staleDate(for: state, now: now), dismissalDate: nil, priority: 10
        )
    }

    /// An update to an activity that last showed `old`. Finished drums alert; phase
    /// changes go out at priority 10, finish-time drift and label changes at 5.
    func update(_ state: LaundryActivityState, since old: LaundryActivityState?, now: Date) -> LiveActivityPush {
        LiveActivityPush(
            event: .update, state: state, timestamp: Self.seconds(now),
            alert: doneAlert(state.drumsFinished(since: old), now: now),
            staleDate: Self.staleDate(for: state, now: now), dismissalDate: nil,
            priority: Self.priority(for: state, since: old)
        )
    }

    func end(_ state: LaundryActivityState, since old: LaundryActivityState?, now: Date, dismissAt: Date? = nil) -> LiveActivityPush {
        LiveActivityPush(
            event: .end, state: state, timestamp: Self.seconds(now),
            alert: doneAlert(state.drumsFinished(since: old), now: now),
            staleDate: nil, dismissalDate: Self.seconds(dismissAt ?? now.addingTimeInterval(dismissAfter)), priority: 10
        )
    }

    static func priority(for state: LaundryActivityState, since old: LaundryActivityState?) -> Int {
        guard let old, old.drums.map(\.id) == state.drums.map(\.id) else { return 10 }
        if !state.drumsFinished(since: old).isEmpty { return 10 }
        return zip(state.drums, old.drums).contains { $0.phase != $1.phase } ? 10 : 5
    }

    /// 15 minutes after the last expected finish, or an hour out when nothing is counting down.
    static func staleDate(for state: LaundryActivityState, now: Date) -> Int {
        if let end = state.drums.compactMap(\.endsAt).max() { return Int(end) + 15 * 60 }
        return seconds(now) + 3600
    }

    static func seconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }

    // MARK: Text

    /// e.g. "Washer started" / "Washing · done around 8:45 PM". Push-to-start requires an alert.
    func startAlert(_ state: LaundryActivityState) -> LiveActivityPush.Alert {
        let active = state.drums.filter(\.isActive)
        let drums = active.isEmpty ? state.drums : active
        let verb = !drums.isEmpty && drums.allSatisfy { $0.phase == .scheduled } ? "scheduled" : "started"
        let title = drums.isEmpty ? "Laundry started" : "\(Self.list(drums.map(\.name))) \(verb)"
        let body = drums.count == 1
            ? summary(drums[0])
            : drums.map { "\($0.name): \(summary($0))" }.joined(separator: "\n")
        return .init(title: title, body: body, sound: nil)
    }

    /// "Washer is done" / "Washer and Dryer are done", with the default sound.
    func doneAlert(_ finished: [LaundryActivityState.Drum], now: Date) -> LiveActivityPush.Alert? {
        guard !finished.isEmpty else { return nil }
        let names = Self.list(finished.map(\.name))
        return .init(
            title: finished.count == 1 ? "\(names) is done" : "\(names) are done",
            body: "Finished at \(clockTime(now.timeIntervalSince1970))",
            sound: "default"
        )
    }

    func summary(_ drum: LaundryActivityState.Drum) -> String {
        switch drum.phase {
        case .scheduled:
            return drum.startsAt.map { "Starts around \(clockTime($0))" } ?? drum.label
        case .paused:
            return drum.pausedMinutes.map { "Paused · \($0) min left" } ?? drum.label
        default:
            return drum.endsAt.map { "\(drum.label) · done around \(clockTime($0))" } ?? drum.label
        }
    }

    /// "8:45 PM" in the Mac's time zone.
    func clockTime(_ seconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + ", and " + names.last!
        }
    }
}

/// What happened to one push.
enum PushOutcome: Equatable, Sendable {
    case sent
    /// APNs says the token is no longer valid (410, or 400 BadDeviceToken/ExpiredToken): forget it.
    case badToken(String)
    case failed(String)
}

/// Sends Live Activity pushes. APNsSender in production, a fake in tests.
protocol LiveActivityPushSender: Sendable {
    func send(_ push: LiveActivityPush, to token: String) async -> PushOutcome
}
