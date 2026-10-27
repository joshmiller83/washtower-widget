import Foundation

/// What the WashTower Live Activity shows. The relay encodes this into APNs pushes
/// ("content-state") and ActivityKit decodes it on the phone, so field names are a
/// wire format: keep them stable. Times are Unix seconds rather than `Date`, because
/// ActivityKit decodes dates as seconds since 2001 and the relay shouldn't have to know.
struct LaundryActivityState: Codable, Hashable, Sendable {
    struct Drum: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var kind: DrumKind
        var name: String
        var phase: DrumPhase
        /// Human state, e.g. "Rinsing".
        var label: String
        /// Cycle start and expected finish while a timer is counting down.
        var startedAt: Double?
        var endsAt: Double?
        /// Frozen time left while paused.
        var pausedMinutes: Int?
        /// When a delayed start begins.
        var startsAt: Double?

        var startDate: Date? { startedAt.map(Date.init(timeIntervalSince1970:)) }
        var endDate: Date? { endsAt.map(Date.init(timeIntervalSince1970:)) }
        var scheduledStart: Date? { startsAt.map(Date.init(timeIntervalSince1970:)) }
        var isActive: Bool { [.running, .paused, .scheduled].contains(phase) }
    }

    var drums: [Drum]
    var updatedAt: Double

    var isActive: Bool { drums.contains(where: \.isActive) }
    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt) }
}

extension LaundryActivityState {
    init(snapshot: LaundrySnapshot) {
        drums = snapshot.drums.map { drum in
            Drum(
                id: drum.id,
                kind: drum.kind,
                name: drum.name,
                phase: drum.phase,
                label: drum.stateLabel,
                startedAt: drum.startDate?.timeIntervalSince1970,
                endsAt: drum.endDate?.timeIntervalSince1970,
                pausedMinutes: drum.phase == .paused ? drum.remainingMinutes : nil,
                startsAt: drum.scheduledStart?.timeIntervalSince1970
            )
        }
        updatedAt = snapshot.fetchedAt.timeIntervalSince1970
    }

    /// Drums that were active in `old` and have since finished, for "Washer is done" alerts.
    func drumsFinished(since old: LaundryActivityState?) -> [Drum] {
        guard let old else { return [] }
        return drums.filter { drum in
            drum.phase == .finished && old.drums.first(where: { $0.id == drum.id })?.isActive == true
        }
    }

    /// True when the phone would show something different: a phase or label change,
    /// a drum appearing, or a finish time moving by more than two minutes.
    func differsVisibly(from old: LaundryActivityState?) -> Bool {
        guard let old, old.drums.map(\.id) == drums.map(\.id) else { return true }
        for (new, previous) in zip(drums, old.drums) {
            if new.phase != previous.phase || new.label != previous.label
                || new.pausedMinutes != previous.pausedMinutes || new.startsAt != previous.startsAt {
                return true
            }
            switch (new.endsAt, previous.endsAt) {
            case let (a?, b?) where abs(a - b) > 120: return true
            case (nil, .some), (.some, nil): return true
            default: continue
            }
        }
        return false
    }

    static var sample: LaundryActivityState { LaundryActivityState(snapshot: .sample) }
}
