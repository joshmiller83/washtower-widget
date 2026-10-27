import ActivityKit
import Foundation

/// The relay names this type in push-to-start payloads ("attributes-type"), so don't rename it.
struct LaundryActivityAttributes: ActivityAttributes {
    typealias ContentState = LaundryActivityState
    var title: String
}

extension LaundryActivityState {
    /// The drums worth showing: anything running or just finished. Falls back to all of them.
    var visibleDrums: [Drum] {
        let shown = drums.filter { $0.isActive || $0.phase == .finished }
        return shown.isEmpty ? drums : shown
    }

    /// The running drum that finishes first, for the compact Dynamic Island.
    var primaryDrum: Drum? {
        drums.filter { $0.endDate != nil }.min { ($0.endsAt ?? 0) < ($1.endsAt ?? 0) }
            ?? visibleDrums.first
    }

    /// When the Live Activity should be considered out of date: a while after the last finish.
    var staleDate: Date {
        let latest = drums.compactMap(\.endDate).max() ?? updatedDate.addingTimeInterval(45 * 60)
        return latest.addingTimeInterval(15 * 60)
    }
}
