import SwiftUI

/// Live countdown for a running drum, or a short status otherwise. Used by the app and the Live Activity.
struct DrumCountdown: View {
    let drum: LaundryActivityState.Drum
    var font: Font = .title2
    /// Timer text reserves room for its widest value, so say which edge it hugs.
    var alignment: TextAlignment = .trailing

    var body: some View {
        Group {
            if let start = drum.startDate, let end = drum.endDate, end > .now {
                Text(timerInterval: min(start, end)...end, countsDown: true)
                    .multilineTextAlignment(alignment)
            } else if drum.phase == .running, drum.endDate != nil {
                Text("0:00")
            } else if drum.phase == .paused, let minutes = drum.pausedMinutes {
                Text(String(format: "%d:%02d", minutes / 60, minutes % 60))
                    .foregroundStyle(.secondary)
            } else if drum.phase == .finished {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text(drum.label).foregroundStyle(.secondary)
            }
        }
        .font(font.monospacedDigit().weight(.semibold))
    }
}

/// A thin progress bar that animates on its own while the timer runs.
struct DrumProgressBar: View {
    let drum: LaundryActivityState.Drum

    var body: some View {
        Group {
            if let start = drum.startDate, let end = drum.endDate, end > .now {
                ProgressView(timerInterval: min(start, end)...end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: drum.phase == .finished || drum.endDate != nil ? 1.0 : 0.0)
            }
        }
        .progressViewStyle(.linear)
        .tint(drum.kind.tint)
    }
}

/// "Rinsing · done 8:45 PM", "Starts 7:30 PM", "Paused", "Done".
struct DrumCaption: View {
    let drum: LaundryActivityState.Drum
    /// Drops "done" for tight spots like the expanded Dynamic Island.
    var compact = false

    var body: some View {
        if let end = drum.endDate, end > .now {
            Text(compact ? "\(drum.label) · \(Text(end, style: .time))" : "\(drum.label) · done \(Text(end, style: .time))")
        } else if drum.phase == .running, drum.endDate != nil {
            Text("Finishing…")
        } else if let start = drum.scheduledStart {
            Text("Starts \(Text(start, style: .time))")
        } else {
            Text(drum.label)
        }
    }
}

/// Icon, name, caption, countdown and progress for one drum.
struct DrumRow: View {
    let drum: LaundryActivityState.Drum
    var countdownFont: Font = .title2

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: drum.kind.symbol)
                    .font(.title3)
                    .foregroundStyle(drum.isActive ? drum.kind.tint : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(drum.name).font(.subheadline.weight(.semibold))
                    DrumCaption(drum: drum)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                DrumCountdown(drum: drum, font: countdownFont)
                    .frame(maxWidth: 110, alignment: .trailing)
            }
            if drum.isActive || drum.phase == .finished {
                DrumProgressBar(drum: drum)
            }
        }
    }
}
