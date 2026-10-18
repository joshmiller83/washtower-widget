import SwiftUI

extension DrumKind {
    var symbol: String {
        switch self {
        case .washer: "washer"
        case .dryer: "dryer"
        case .other: "bubbles.and.sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .washer: .blue
        case .dryer: .orange
        case .other: .teal
        }
    }
}

extension DrumStatus {
    /// "1:05" style hours:minutes left, counted from `now`. Nil when no timer is running.
    /// Rounds down, so it reads the same as the hours:minutes of the widget's live timer.
    func remainingText(at now: Date = Date()) -> String? {
        let minutes: Int
        if let end = endDate {
            minutes = max(0, Int(end.timeIntervalSince(now) / 60))
        } else if phase == .paused, let remaining = remainingMinutes {
            minutes = remaining
        } else {
            return nil
        }
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
