import SwiftUI
import WidgetKit
import AppIntents

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    let options: DisplayOptions
    var repo: String? = nil   // Sessions widget: the repository it is filtered to (nil = all)
}

struct UsageProvider: TimelineProvider {
    private func options() -> DisplayOptions {
        let o = AppSettings.snapshot()
        L10n.forceEnglish = o[.forceEnglishWidgets]
        return o
    }

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: .placeholder, options: options())
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let snap = context.isPreview ? UsageSnapshot.placeholder : (SnapshotStore.load() ?? .placeholder)
        completion(UsageEntry(date: .now, snapshot: snap, options: options()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let options = options()
        // Record the real widget size per family (read back with `--sizes`).
        AppSettings.defaults.set("\(Int(context.displaySize.width))x\(Int(context.displaySize.height))", forKey: "debug_size_\(context.family)")
        var snap = SnapshotStore.load() ?? UsageSnapshot(
            fetchedAt: .distantPast, windows: [], extraUsage: nil, profile: nil, serviceStatus: nil,
            sessions: [], today: nil, tokenState: .missing,
            errorMessage: L("Open Orbit to fetch")
        )
        let now = Date.now
        // The app refreshes every `refreshMinutes`. If the snapshot is older than twice that, the app is probably
        // not running: fetch usage and status here with the shared access token (sessions/today stay as they were).
        let stale = now.timeIntervalSince(snap.fetchedAt) > Double(options.refreshMinutes * 2 * 60)
        if stale, let token = SharedToken.load(), token.expiresAt > now.addingTimeInterval(60) {
            Task {
                async let status: ServiceStatus? = options[.showServiceStatus] ? (try? await StatusAPI.fetch()) : nil
                if let u = try? await ClaudeAPI.fetchUsage(token: token.accessToken) {
                    snap.windows = u.windows; snap.extraUsage = u.extra; snap.rawUsageJSON = u.raw; snap.breakdown = u.breakdown
                    snap.tokenState = .ok; snap.errorMessage = nil
                }
                if let st = await status { snap.serviceStatus = st }
                snap.fetchedAt = now
                try? SnapshotStore.save(snap)
                completion(Self.timeline(snap, options: options, now: now, entries: 6))   // re-check in 30 min
            }
            return
        }
        completion(Self.timeline(snap, options: options, now: now, entries: 12))
    }

    /// Entries every 5 minutes so the pace marker and clock move without a network call.
    private static func timeline(_ snap: UsageSnapshot, options: DisplayOptions, now: Date, entries: Int) -> Timeline<UsageEntry> {
        let list = (0..<entries).map { i in UsageEntry(date: now.addingTimeInterval(Double(i) * 300), snapshot: snap, options: options) }
        return Timeline(entries: list, policy: .atEnd)
    }
}

/// The Sessions widget's provider: the same entries as `UsageProvider`, tagged with the configured repository.
struct SessionsProvider: AppIntentTimelineProvider {
    private let base = UsageProvider()

    func placeholder(in context: Context) -> UsageEntry { base.placeholder(in: context) }

    func snapshot(for configuration: SessionsFilterIntent, in context: Context) async -> UsageEntry {
        let e = await withCheckedContinuation { c in base.getSnapshot(in: context) { c.resume(returning: $0) } }
        return UsageEntry(date: e.date, snapshot: e.snapshot, options: e.options, repo: configuration.repo)
    }

    func timeline(for configuration: SessionsFilterIntent, in context: Context) async -> Timeline<UsageEntry> {
        let t = await withCheckedContinuation { c in base.getTimeline(in: context) { c.resume(returning: $0) } }
        return Timeline(entries: t.entries.map { UsageEntry(date: $0.date, snapshot: $0.snapshot, options: $0.options, repo: configuration.repo) },
                        policy: t.policy)
    }
}

struct ClaudeUsageWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    var entry: UsageEntry

    private var size: DashboardSize {
        switch family {
        case .systemSmall: return .small
        case .systemLarge, .systemExtraLarge: return .large
        default: return .medium
        }
    }

    private var level: UsageLevel {
        entry.options.headlineLevel(entry.snapshot, at: entry.date)   // Glass Orbit's glow follows the headline (the forecast)
    }

    var body: some View {
        let options = entry.options.withCurrentStyle()
        UsageDashboardView(snapshot: entry.snapshot, options: options, size: size, now: entry.date, inWidget: true, refreshable: true)
            .modifier(DrawPlaceholder())
            .containerBackground(for: .widget) {
                // In accented/clear (Liquid Glass) rendering the system paints its own glass; keep it transparent.
                if renderingMode == .fullColor {
                    DashboardBackground(style: options.style, level: level)
                } else {
                    Color.clear
                }
            }
    }
}

/// Shared chrome for the secondary widgets: 18pt system margins, style background, same entry/timeline.
struct SecondaryWidgetEntryView<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    var entry: UsageEntry
    var alert: Bool = false          // incident: draw a warning halo inside the widget edge
    var content: (DashboardSize) -> Content

    private var size: DashboardSize {
        switch family {
        case .systemSmall: return .small
        case .systemLarge, .systemExtraLarge: return .large
        default: return .medium
        }
    }

    var body: some View {
        content(size)
            .modifier(DrawPlaceholder())
            .containerBackground(for: .widget) {
                ZStack {
                    if renderingMode == .fullColor {
                        DashboardBackground(style: entry.options.withCurrentStyle().style, level: alert ? .wellAboveTarget : .onTrack)
                    } else {
                        Color.clear
                    }
                    if alert {
                        ContainerRelativeShape()
                            .stroke(Palette.status(entry.snapshot.serviceStatus), lineWidth: 3)
                            .padding(1)
                            .shadow(color: Palette.status(entry.snapshot.serviceStatus).opacity(0.8), radius: 8)
                    }
                }
            }
    }
}

struct OrbitUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppConstants.widgetKind, provider: UsageProvider()) { entry in
            ClaudeUsageWidgetEntryView(entry: entry)
                .widgetURL(URL(string: "https://claude.ai/settings/usage")!)   // tap → usage page on claude.ai
        }
        .configurationDisplayName(Text(L("Usage")))
        .description(Text(L("Shows Claude Code's 5-hour / weekly usage, service status and running sessions.")))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OrbitSessionsWidget: Widget {
    var body: some WidgetConfiguration {
        // Configurable ("Edit Widget" → Repository): one widget per repository, or all of them.
        AppIntentConfiguration(kind: "OrbitSessionsWidget", intent: SessionsFilterIntent.self, provider: SessionsProvider()) { entry in
            SecondaryWidgetEntryView(entry: entry) { size in
                SessionsWidgetView(snapshot: entry.snapshot, options: entry.options.withCurrentStyle(), size: size, now: entry.date, repo: entry.repo)
            }
            .widgetURL(URL(string: "orbit://sessions")!)   // small widget / empty area → bring the Claude app forward
        }
        .configurationDisplayName(Text(L("Sessions")))
        .description(Text(L("Running Claude Code sessions: project, uptime and where they were started.")))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OrbitCoworkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OrbitCoworkWidget", provider: UsageProvider()) { entry in
            SecondaryWidgetEntryView(entry: entry) { size in
                CoworkWidgetView(snapshot: entry.snapshot, options: entry.options.withCurrentStyle(), size: size, now: entry.date)
            }
            .widgetURL(URL(string: "orbit://cowork")!)   // tap → bring the Claude app forward
        }
        .configurationDisplayName(Text(L("Cowork")))
        .description(Text(L("Recent Cowork sessions from the Claude desktop app.")))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OrbitStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OrbitStatusWidget", provider: UsageProvider()) { entry in
            SecondaryWidgetEntryView(entry: entry, alert: entry.snapshot.serviceStatus.map { !$0.isHealthy } ?? false) { size in
                StatusWidgetView(snapshot: entry.snapshot, options: entry.options.withCurrentStyle(), size: size, now: entry.date)
            }
            .widgetURL(URL(string: "https://status.claude.com")!)   // tap → the app opens it in the browser
        }
        .configurationDisplayName(Text(L("Claude status")))
        .description(Text(L("Service status from status.claude.com: overall, per component, and open incidents.")))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OrbitTodayWidget", provider: UsageProvider()) { entry in
            SecondaryWidgetEntryView(entry: entry) { size in
                TodayWidgetView(snapshot: entry.snapshot, options: entry.options.withCurrentStyle(), size: size, now: entry.date)
            }
            .widgetURL(URL(string: "orbit://refresh")!)   // tap → fetch now
        }
        .configurationDisplayName(Text(L("Today")))
        .description(Text(L("Today's tokens and API-equivalent cost from local Claude Code logs, by model.")))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct OrbitWidgets: WidgetBundle {
    var body: some Widget {
        OrbitUsageWidget()
        OrbitSessionsWidget()
        OrbitCoworkWidget()
        OrbitStatusWidget()
        OrbitTodayWidget()
    }
}

#Preview("Medium", as: .systemMedium) {
    OrbitUsageWidget()
} timeline: {
    UsageEntry(date: .now, snapshot: .placeholder, options: .all)
}
