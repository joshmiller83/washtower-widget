import AppIntents
import SwiftUI
import WidgetKit

@main
struct LaundryWidgetBundle: WidgetBundle {
    var body: some Widget {
        LaundryWidget()
    }
}

struct LaundryWidget: Widget {
    static let kind = "LaundryWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: LaundryConfigurationIntent.self, provider: LaundryProvider()) { entry in
            LaundryWidgetView(entry: entry)
        }
        .configurationDisplayName("WashTower")
        .description("Live washer and dryer countdowns from LG ThinQ.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Intents

enum DrumFilter: String, AppEnum {
    case both, washer, dryer

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Drums" }
    static var caseDisplayRepresentations: [DrumFilter: DisplayRepresentation] {
        [.both: "Both", .washer: "Washer only", .dryer: "Dryer only"]
    }

    func includes(_ kind: DrumKind) -> Bool {
        switch self {
        case .both: true
        case .washer: kind == .washer
        case .dryer: kind == .dryer
        }
    }
}

struct LaundryConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "WashTower" }
    static var description: IntentDescription { "Choose which drums the widget shows." }

    @Parameter(title: "Show", default: .both)
    var show: DrumFilter
}

/// Run by the widget's refresh button. WidgetKit reloads the timeline when it returns,
/// and the provider then picks up the snapshot this just saved.
struct RefreshLaundryIntent: AppIntent {
    static var title: LocalizedStringResource { "Refresh Laundry" }
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        _ = try? await LaundryService.refresh()
        return .result()
    }
}

// MARK: - Timeline

struct LaundryEntry: TimelineEntry {
    var date: Date
    var snapshot: LaundrySnapshot?
    var error: String? = nil
    var show: DrumFilter = .both
    var hasToken = true
}

struct LaundryProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LaundryEntry {
        LaundryEntry(date: .now, snapshot: .sample)
    }

    func snapshot(for configuration: LaundryConfigurationIntent, in context: Context) async -> LaundryEntry {
        if !context.isPreview, let saved = SharedStore.snapshot {
            return LaundryEntry(date: .now, snapshot: saved, show: configuration.show, hasToken: SharedStore.token != nil)
        }
        return LaundryEntry(date: .now, snapshot: .sample, show: configuration.show)
    }

    func timeline(for configuration: LaundryConfigurationIntent, in context: Context) async -> Timeline<LaundryEntry> {
        let now = Date()
        // Nothing to fetch without a token; the app reloads timelines once one is saved.
        guard SharedStore.token != nil else {
            let entry = LaundryEntry(date: now, snapshot: nil, show: configuration.show, hasToken: false)
            return Timeline(entries: [entry], policy: .after(now + 3600))
        }

        let (snapshot, error) = await LaundryService.current(maxAge: 50)
        // One entry now, plus one at each finish time so a countdown that reaches 0:00
        // flips to "Finishing…" until the next fetch confirms the drum is done.
        let finishTimes = Set(snapshot?.drums.compactMap(\.endDate) ?? []).filter { $0 > now }.sorted()
        let entries = ([now] + finishTimes).map {
            LaundryEntry(date: $0, snapshot: snapshot, error: error, show: configuration.show)
        }
        return Timeline(entries: entries, policy: .after(Self.nextReload(snapshot: snapshot, error: error, now: now)))
    }

    /// Countdowns tick on their own, so reloads are only for picking up new state (the
    /// running app also pushes reloads on every change). While a drum is active, check back
    /// shortly after the next finish or delayed start, at most 15 minutes out.
    static func nextReload(snapshot: LaundrySnapshot?, error: String?, now: Date) -> Date {
        let cap = now + 15 * 60
        guard let snapshot, snapshot.hasActiveDrum else {
            return now + (error == nil ? 3600 : 1800)
        }
        // After a failed fetch the saved finish times may be long past; don't retry every minute.
        guard error == nil, let next = snapshot.drums.compactMap({ $0.endDate ?? $0.scheduledStart }).min() else {
            return cap
        }
        return min(max(next + 90, now + 60), cap)
    }
}

// MARK: - Drum display rules

fileprivate extension DrumStatus {
    /// The live countdown interval, while the extrapolated timer is still running at `date`.
    func timerRange(at date: Date) -> ClosedRange<Date>? {
        guard let end = endDate, end > date else { return nil }
        return min(startDate ?? date, end)...end
    }

    /// The timer hit zero but no fetch has reported the drum finished yet.
    func isFinishing(at date: Date) -> Bool {
        guard let end = endDate else { return false }
        return end <= date
    }

    /// The smaller line under the main value, if any.
    func caption(at date: Date) -> String? {
        switch phase {
        case .running:
            if isFinishing(at: date) { return "Finishing…" }
            return endDate == nil ? nil : stateLabel
        case .paused:
            return remainingText(at: date) == nil ? nil : "Paused"
        default:
            return nil
        }
    }

    var isDimmed: Bool { phase == .off || phase == .idle }
}

// MARK: - Views

struct LaundryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LaundryEntry

    var body: some View {
        content
            .containerBackground(for: .widget) {
                Rectangle().fill(.background)
            }
    }

    @ViewBuilder private var content: some View {
        if !entry.hasToken {
            MessageView(symbol: "person.crop.circle.badge.plus", text: "Open WashTower Widget to connect your LG account")
        } else if let snapshot = entry.snapshot {
            let drums = snapshot.drums.filter { entry.show.includes($0.kind) }
            if drums.isEmpty {
                MessageView(symbol: "washer", text: emptyText, showsRefresh: true)
            } else {
                drumsView(Array(drums.prefix(2)), snapshot: snapshot)
                    .invalidatableContent()
            }
        } else {
            MessageView(symbol: "exclamationmark.triangle", text: entry.error ?? "Couldn't reach LG ThinQ", showsRefresh: true)
        }
    }

    private var emptyText: String {
        switch entry.show {
        case .both: "No LG washer or dryer found"
        case .washer: "No LG washer found"
        case .dryer: "No LG dryer found"
        }
    }

    @ViewBuilder private func drumsView(_ drums: [DrumStatus], snapshot: LaundrySnapshot) -> some View {
        if family == .systemSmall {
            if drums.count == 1 {
                DrumDetail(drum: drums[0], date: entry.date, valueSize: 34, showsRefresh: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(drums) { drum in
                        DrumRow(drum: drum, date: entry.date, showsRefresh: drum.id == drums.first?.id)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 16) {
                    ForEach(drums) { drum in
                        DrumDetail(drum: drum, date: entry.date, valueSize: 30, showsRefresh: drum.id == drums.last?.id)
                    }
                }
                if entry.date.timeIntervalSince(snapshot.fetchedAt) > 20 * 60 {
                    Text("Updated \(Text(snapshot.fetchedAt, style: .time))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// Name on top, value block at the bottom. Used for medium columns and a lone drum in a small widget.
struct DrumDetail: View {
    let drum: DrumStatus
    let date: Date
    let valueSize: CGFloat
    let showsRefresh: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                DrumIcon(drum: drum)
                Text(drum.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if showsRefresh { RefreshButton() }
            }
            .font(.subheadline.weight(.semibold))

            Spacer(minLength: 4)

            // Every line below is always present (blank when unused) so side-by-side columns line up.
            DrumValue(drum: drum, date: date, size: valueSize)
            Text(drum.caption(at: date) ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            DrumProgress(drum: drum, date: date)
                .padding(.vertical, 2)
            Group {
                if let end = drum.timerRange(at: date)?.upperBound {
                    Text("Done \(Text(end, style: .time))")
                } else {
                    Text(" ")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One of two stacked drums in a small widget.
struct DrumRow: View {
    let drum: DrumStatus
    let date: Date
    let showsRefresh: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                DrumIcon(drum: drum)
                    .font(.system(size: 17))
                    .frame(width: 22, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    DrumValue(drum: drum, date: date, size: 22)
                    // There's no room for a header here, so drums without a caption show their name.
                    Text(drum.caption(at: date) ?? drum.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if showsRefresh { RefreshButton() }
            }
            DrumProgress(drum: drum, date: date)
        }
    }
}

/// The main line: a live countdown while the timer runs, otherwise a short status.
struct DrumValue: View {
    let drum: DrumStatus
    let date: Date
    let size: CGFloat

    var body: some View {
        value
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.leading)
            // Timer text reserves room for its widest value, so pin it to the leading edge
            // and give every state the same height.
            .frame(maxWidth: .infinity, minHeight: size * 1.2, alignment: .leading)
    }

    private var bigFont: Font { .system(size: size, weight: .semibold, design: .rounded).monospacedDigit() }
    private var statusFont: Font { .system(size: (size * 0.62).rounded(), weight: .semibold, design: .rounded) }

    @ViewBuilder private var value: some View {
        if let range = drum.timerRange(at: date) {
            Text(timerInterval: range, countsDown: true)
                .font(bigFont)
                .widgetAccentable()
        } else {
            switch drum.phase {
            case .running:
                if drum.isFinishing(at: date) {
                    Text("0:00").font(bigFont)
                } else {
                    Text(drum.stateLabel).font(statusFont)
                }
            case .paused:
                if let remaining = drum.remainingText(at: date) {
                    Text(remaining).font(bigFont).foregroundStyle(.secondary)
                } else {
                    Text("Paused").font(statusFont)
                }
            case .scheduled:
                if let start = drum.scheduledStart {
                    Text("Starts \(Text(start, style: .time))").font(statusFont)
                } else {
                    Text("Delayed start").font(statusFont)
                }
            case .finished:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .widgetAccentable()
                    Text("Done")
                }
                .font(statusFont)
            case .error:
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .widgetAccentable()
                    Text("Error")
                }
                .font(statusFont)
            case .off, .idle:
                Text(drum.stateLabel)
                    .font(statusFont)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A thin bar in the drum's color. Always occupies the same height so layouts don't jump.
struct DrumProgress: View {
    let drum: DrumStatus
    let date: Date

    var body: some View {
        Group {
            if let range = drum.timerRange(at: date) {
                // Animates on its own; the explicit empty labels suppress the default time label.
                ProgressView(timerInterval: range, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
            } else if drum.isFinishing(at: date) {
                ProgressView(value: 1.0)
            } else if drum.phase == .paused, let total = drum.totalMinutes, total > 0, let remaining = drum.remainingMinutes {
                ProgressView(value: Double(max(total - remaining, 0)), total: Double(total))
            } else {
                ProgressView(value: 0.0).hidden()
            }
        }
        .progressViewStyle(.linear)
        .tint(drum.kind.tint)
        .widgetAccentable()
    }
}

struct DrumIcon: View {
    let drum: DrumStatus

    var body: some View {
        Image(systemName: drum.kind.symbol)
            .foregroundStyle(drum.kind.tint)
            .widgetAccentable()
            .opacity(drum.isDimmed ? 0.45 : 1)
    }
}

struct RefreshButton: View {
    var body: some View {
        Button(intent: RefreshLaundryIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh")
    }
}

struct MessageView: View {
    let symbol: String
    let text: String
    var showsRefresh = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .widgetAccentable()
            Text(text)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if showsRefresh { RefreshButton() }
        }
    }
}

// MARK: - Previews

private extension LaundrySnapshot {
    /// A finished washer and a paused dryer, old enough to show the "Updated" footer.
    static var previewMixed: LaundrySnapshot {
        let fetched = Date().addingTimeInterval(-25 * 60)
        return LaundrySnapshot(drums: [
            DrumStatus(id: "preview-washer", kind: .washer, name: "Washer", state: "END",
                       remainingMinutes: 0, totalMinutes: 58, startsInMinutes: nil, fetchedAt: fetched),
            DrumStatus(id: "preview-dryer", kind: .dryer, name: "Dryer", state: "PAUSE",
                       remainingMinutes: 40, totalMinutes: 90, startsInMinutes: nil, fetchedAt: fetched),
        ], fetchedAt: fetched)
    }
}

#Preview("Small", as: .systemSmall) {
    LaundryWidget()
} timeline: {
    LaundryEntry(date: .now, snapshot: .sample)
    LaundryEntry(date: .now, snapshot: .sample, show: .dryer)
    LaundryEntry(date: .now, snapshot: .previewMixed)
    LaundryEntry(date: .now, snapshot: nil, hasToken: false)
}

#Preview("Medium", as: .systemMedium) {
    LaundryWidget()
} timeline: {
    LaundryEntry(date: .now, snapshot: .sample)
    LaundryEntry(date: .now, snapshot: .previewMixed)
    LaundryEntry(date: .now, snapshot: LaundrySnapshot(drums: [], fetchedAt: .now))
}
