import Foundation

enum DrumKind: String, Codable, Sendable {
    case washer, dryer, other

    init(deviceType: String) {
        let type = deviceType.uppercased()
        // Check DRYER first: a WashTower's dryer reports DEVICE_WASHTOWER_DRYER.
        if type.contains("DRYER") {
            self = .dryer
        } else if type.contains("WASH") {
            self = .washer
        } else {
            self = .other
        }
    }

    var defaultName: String {
        switch self {
        case .washer: "Washer"
        case .dryer: "Dryer"
        case .other: "Laundry"
        }
    }

    var sortOrder: Int {
        switch self {
        case .washer: 0
        case .dryer: 1
        case .other: 2
        }
    }
}

/// What a drum is doing, collapsed from ThinQ's many run states.
enum DrumPhase: String, Codable, Sendable {
    case off, idle, running, paused, scheduled, finished, error
}

/// One drum (washer or dryer) as of the last fetch.
struct DrumStatus: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var kind: DrumKind
    var name: String
    /// Raw `runState.currentState` from ThinQ, e.g. "RINSING".
    var state: String
    var remainingMinutes: Int?
    var totalMinutes: Int?
    /// Minutes until a delayed start begins.
    var startsInMinutes: Int?
    var fetchedAt: Date

    var phase: DrumPhase {
        switch state {
        case "POWER_OFF": .off
        case "INITIAL", "STANDBY", "SLEEP", "": .idle
        case "END": .finished
        case "PAUSE": .paused
        case "RESERVED": .scheduled
        case "ERROR": .error
        default: .running
        }
    }

    /// Expected finish time, extrapolated from the last fetch. Only set while a timer is counting down.
    var endDate: Date? {
        guard phase == .running, let remaining = remainingMinutes, remaining > 0 else { return nil }
        return fetchedAt.addingTimeInterval(TimeInterval(remaining * 60))
    }

    /// When the cycle began, for progress bars. ThinQ's total can drift below the remaining time, so clamp.
    var startDate: Date? {
        guard let end = endDate else { return nil }
        let total = max(totalMinutes ?? 0, remainingMinutes ?? 0)
        return end.addingTimeInterval(-TimeInterval(total * 60))
    }

    var scheduledStart: Date? {
        guard phase == .scheduled, let minutes = startsInMinutes, minutes > 0 else { return nil }
        return fetchedAt.addingTimeInterval(TimeInterval(minutes * 60))
    }

    var isActive: Bool { [.running, .paused, .scheduled].contains(phase) }

    var stateLabel: String {
        switch state {
        case "POWER_OFF": return "Off"
        case "INITIAL", "STANDBY", "": return "Ready"
        case "SLEEP": return "Sleeping"
        case "END": return "Done"
        case "PAUSE": return "Paused"
        case "RESERVED": return "Delayed start"
        case "ERROR": return "Error"
        case "DETECTING": return "Sensing load"
        case "RUNNING":
            switch kind {
            case .washer: return "Washing"
            case .dryer: return "Drying"
            case .other: return "Running"
            }
        default:
            // RINSING -> "Rinsing", WRINKLE_CARE -> "Wrinkle care"
            let words = state.replacingOccurrences(of: "_", with: " ").lowercased()
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
}

struct LaundrySnapshot: Codable, Sendable, Equatable {
    var drums: [DrumStatus]
    var fetchedAt: Date

    var nextEndDate: Date? { drums.compactMap(\.endDate).min() }
    var hasActiveDrum: Bool { drums.contains(where: \.isActive) }

    /// True when something a viewer would notice changed, so the app only asks
    /// WidgetKit to reload (which has a daily budget) when it matters.
    func needsWidgetReload(comparedTo old: LaundrySnapshot?) -> Bool {
        guard let old, old.drums.map(\.id) == drums.map(\.id) else { return true }
        for (new, previous) in zip(drums, old.drums) {
            if new.state != previous.state || new.startsInMinutes != previous.startsInMinutes { return true }
            switch (new.endDate, previous.endDate) {
            case let (a?, b?) where abs(a.timeIntervalSince(b)) > 120: return true
            case (nil, .some), (.some, nil): return true
            default: continue
            }
        }
        return false
    }

    /// Shown in the widget gallery and in previews.
    static var sample: LaundrySnapshot {
        let now = Date()
        return LaundrySnapshot(drums: [
            DrumStatus(id: "sample-washer", kind: .washer, name: "Washer", state: "RINSING",
                       remainingMinutes: 23, totalMinutes: 58, startsInMinutes: nil, fetchedAt: now),
            DrumStatus(id: "sample-dryer", kind: .dryer, name: "Dryer", state: "RUNNING",
                       remainingMinutes: 65, totalMinutes: 90, startsInMinutes: nil, fetchedAt: now),
        ], fetchedAt: now)
    }
}

/// Turns ThinQ state JSON into drums. Handles all three shapes LG returns:
/// a WashTower as {"washer": ..., "dryer": ...}, a single machine as a dict,
/// and multi-drum machines as a list tagged with `location`.
enum ThinQParser {
    static func drums(deviceID: String, deviceType: String, state: Any?, fetchedAt: Date) -> [DrumStatus] {
        if let dict = state as? [String: Any], dict["washer"] != nil || dict["dryer"] != nil {
            return ["washer", "dryer"].flatMap { key in
                drums(deviceID: "\(deviceID):\(key)", deviceType: key, state: dict[key], fetchedAt: fetchedAt)
            }
        }
        let items = (state as? [[String: Any]]) ?? (state as? [String: Any]).map { [$0] } ?? []
        let kind = DrumKind(deviceType: deviceType)
        return items.map { item in
            let location = (item["location"] as? [String: Any])?["locationName"] as? String
            let runState = (item["runState"] as? [String: Any])?["currentState"] as? String ?? ""
            let timer = item["timer"] as? [String: Any] ?? [:]
            func minutes(_ hourKey: String, _ minuteKey: String) -> Int? {
                guard timer[hourKey] != nil || timer[minuteKey] != nil else { return nil }
                return int(timer[hourKey]) * 60 + int(timer[minuteKey])
            }
            var name = kind.defaultName
            var id = deviceID
            if let location {
                id += ":\(location)"
                if location != "MAIN" { name += " (\(location.capitalized))" }
            }
            return DrumStatus(
                id: id, kind: kind, name: name, state: runState,
                remainingMinutes: minutes("remainHour", "remainMinute"),
                totalMinutes: minutes("totalHour", "totalMinute"),
                startsInMinutes: minutes("relativeHourToStart", "relativeMinuteToStart"),
                fetchedAt: fetchedAt
            )
        }
    }

    private static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }
}
