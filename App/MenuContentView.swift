import SwiftUI

struct MenuContentView: View {
    let model: LaundryModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Laundry").font(.headline)
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.pulse, isActive: model.isRefreshing)
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
                .disabled(!model.hasToken)
            }

            if !model.hasToken {
                Text("Connect your LG ThinQ account to see your washer and dryer.")
                    .foregroundStyle(.secondary)
            } else if let drums = model.snapshot?.drums, !drums.isEmpty {
                ForEach(drums) { DrumRow(drum: $0) }
            } else if model.snapshot != nil {
                Text("No LG washer or dryer found on this account.")
                    .foregroundStyle(.secondary)
            } else if model.lastError == nil {
                ProgressView().controlSize(.small)
            }

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            HStack {
                if let fetched = model.snapshot?.fetchedAt {
                    Text("Updated \(fetched, style: .time)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate()
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
    }
}

private struct DrumRow: View {
    let drum: DrumStatus

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: drum.kind.symbol)
                .font(.title2)
                .foregroundStyle(drum.isActive ? drum.kind.tint : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(drum.name).font(.subheadline.weight(.semibold))
                    Text(drum.stateLabel).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    countdown
                }
                if let start = drum.startDate, let end = drum.endDate, end > Date() {
                    ProgressView(timerInterval: start...end, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .tint(drum.kind.tint)
                    Text("Done around \(end, style: .time)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let start = drum.scheduledStart {
                    Text("Starts at \(start, style: .time)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var countdown: some View {
        if let start = drum.startDate, let end = drum.endDate, end > Date() {
            Text(timerInterval: start...end, countsDown: true)
                .font(.title3.monospacedDigit().weight(.medium))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90, alignment: .trailing)
        } else if let text = drum.remainingText() {
            Text(text).font(.title3.monospacedDigit().weight(.medium))
        }
    }
}
