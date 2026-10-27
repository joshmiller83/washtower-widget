import ActivityKit
import SwiftUI
import WidgetKit

@main
struct WashTowerLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        LaundryLiveActivity()
    }
}

struct LaundryLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LaundryActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let state = context.state
            let drums = state.visibleDrums
            return DynamicIsland {
                // Regions can't be conditional, so each one decides between the
                // two-drum layout (a column per drum) and the one-drum layout.
                DynamicIslandExpandedRegion(.leading) { ExpandedLeading(drums: drums) }
                DynamicIslandExpandedRegion(.trailing) { ExpandedTrailing(drums: drums) }
                DynamicIslandExpandedRegion(.bottom) { ExpandedBottom(drums: drums) }
            } compactLeading: {
                HStack(spacing: 2) {
                    ForEach(drums.prefix(2)) { drum in
                        Image(systemName: drum.kind.symbol)
                            .foregroundStyle(drum.isActive ? drum.kind.tint : .secondary)
                    }
                }
            } compactTrailing: {
                if let drum = state.primaryDrum {
                    CompactCountdown(drum: drum)
                }
            } minimal: {
                if let drum = state.primaryDrum {
                    Image(systemName: drum.kind.symbol).foregroundStyle(drum.kind.tint)
                }
            }
            .keylineTint(state.primaryDrum?.kind.tint)
        }
        // The Watch Smart Stack and CarPlay use the .small family.
        .supplementalActivityFamilies([.small, .medium])
    }
}

/// Lock Screen, notification banner, StandBy, and the Mac menu bar's expanded view.
struct LockScreenView: View {
    let state: LaundryActivityState
    @Environment(\.activityFamily) private var family

    var body: some View {
        if family == .small {
            SmallView(state: state)
        } else {
            VStack(spacing: 12) {
                ForEach(state.visibleDrums) { drum in
                    DrumRow(drum: drum, countdownFont: .title2)
                }
            }
            .padding(16)
        }
    }
}

/// Apple Watch Smart Stack and CarPlay: one line per drum.
struct SmallView: View {
    let state: LaundryActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.visibleDrums.prefix(2)) { drum in
                HStack(spacing: 6) {
                    Image(systemName: drum.kind.symbol)
                        .foregroundStyle(drum.kind.tint)
                    DrumCountdown(drum: drum, font: .body)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(8)
    }
}

struct ExpandedLeading: View {
    let drums: [LaundryActivityState.Drum]

    var body: some View {
        if drums.count >= 2 {
            ExpandedDrum(drum: drums[0], edge: .leading)
        } else if let drum = drums.first {
            Label(drum.name, systemImage: drum.kind.symbol)
                .font(.headline)
                .foregroundStyle(drum.kind.tint)
                .padding(.horizontal, 4)
        }
    }
}

struct ExpandedTrailing: View {
    let drums: [LaundryActivityState.Drum]

    var body: some View {
        if drums.count >= 2 {
            ExpandedDrum(drum: drums[1], edge: .trailing)
        } else if let drum = drums.first {
            DrumCountdown(drum: drum, font: .title2)
                .padding(.horizontal, 4)
        }
    }
}

struct ExpandedBottom: View {
    let drums: [LaundryActivityState.Drum]

    var body: some View {
        if drums.count >= 2 {
            HStack(spacing: 16) {
                DrumProgressBar(drum: drums[0])
                DrumProgressBar(drum: drums[1])
            }
            .padding(.horizontal, 4)
        } else if let drum = drums.first {
            VStack(alignment: .leading, spacing: 6) {
                DrumProgressBar(drum: drum)
                DrumCaption(drum: drum).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }
}

/// One half of the expanded Dynamic Island when both drums are going.
struct ExpandedDrum: View {
    let drum: LaundryActivityState.Drum
    /// Which side of the island this column sits on; everything hugs that edge.
    let edge: HorizontalEdge

    var body: some View {
        let alignment: HorizontalAlignment = edge == .leading ? .leading : .trailing
        VStack(alignment: alignment, spacing: 2) {
            Label(drum.name, systemImage: drum.kind.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(drum.kind.tint)
            DrumCountdown(drum: drum, font: .title3, alignment: edge == .leading ? .leading : .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            DrumCaption(drum: drum, compact: true)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .padding(.horizontal, 4)
    }
}

/// The compact Dynamic Island timer. Timer text sizes itself for its widest value,
/// so give it a fixed width that fits "0:00" or "1:00:00".
struct CompactCountdown: View {
    let drum: LaundryActivityState.Drum

    var body: some View {
        if let start = drum.startDate, let end = drum.endDate, end > .now {
            Text(timerInterval: min(start, end)...end, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: end.timeIntervalSinceNow >= 3600 ? 58 : 42)
                .foregroundStyle(drum.kind.tint)
        } else if drum.phase == .finished {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Text(drum.label).font(.caption2).lineLimit(1)
        }
    }
}

#Preview("Lock Screen", as: .content, using: LaundryActivityAttributes(title: "WashTower")) {
    LaundryLiveActivity()
} contentStates: {
    LaundryActivityState.sample
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: LaundryActivityAttributes(title: "WashTower")) {
    LaundryLiveActivity()
} contentStates: {
    LaundryActivityState.sample
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: LaundryActivityAttributes(title: "WashTower")) {
    LaundryLiveActivity()
} contentStates: {
    LaundryActivityState.sample
}
