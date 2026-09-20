import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    let options: DisplayOptions
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
        // Record the real widget size per family (read back with `ClaudeUsage --sizes`).
        AppSettings.defaults.set("\(Int(context.displaySize.width))x\(Int(context.displaySize.height))", forKey: "debug_size_\(context.family)")
        let snap = SnapshotStore.load() ?? UsageSnapshot(
            fetchedAt: .now, windows: [], extraUsage: nil, profile: nil, serviceStatus: nil,
            sessions: [], today: nil, tokenState: .missing,
            errorMessage: "Open ClaudeUsage to fetch"
        )
        // Re-render every few minutes so the pace marker and clock move without a network call.
        let now = Date.now
        let entries = (0..<12).map { i in
            UsageEntry(date: now.addingTimeInterval(Double(i) * 300), snapshot: snap, options: options)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
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
        entry.snapshot.worstWindow(at: entry.date, visible: Set(entry.options.visibleWindows(entry.snapshot).map(\.id)))?.level(at: entry.date) ?? .onTrack
    }

    var body: some View {
        UsageDashboardView(snapshot: entry.snapshot, options: entry.options, size: size, now: entry.date, inWidget: true)
            .containerBackground(for: .widget) {
                // In accented/clear (Liquid Glass) rendering the system paints its own glass; keep it transparent.
                if renderingMode == .fullColor {
                    DashboardBackground(style: entry.options.style, level: level)
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
            .containerBackground(for: .widget) {
                if renderingMode == .fullColor {
                    DashboardBackground(style: entry.options.style, level: .onTrack)
                } else {
                    Color.clear
                }
            }
    }
}

struct OrbitUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppConstants.widgetKind, provider: UsageProvider()) { entry in
            ClaudeUsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(Text(L("Usage")))
        .description(Text(L("Shows Claude Code's 5-hour / weekly usage, service status and running sessions.")))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OrbitSessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OrbitSessionsWidget", provider: UsageProvider()) { entry in
            SecondaryWidgetEntryView(entry: entry) { size in
                SessionsWidgetView(snapshot: entry.snapshot, options: entry.options, size: size, now: entry.date)
            }
        }
        .configurationDisplayName(Text(L("Sessions")))
        .description(Text(L("Running Claude Code sessions: project, uptime and where they were started.")))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OrbitStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OrbitStatusWidget", provider: UsageProvider()) { entry in
            SecondaryWidgetEntryView(entry: entry) { size in
                StatusWidgetView(snapshot: entry.snapshot, options: entry.options, size: size, now: entry.date)
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
                TodayWidgetView(snapshot: entry.snapshot, options: entry.options, size: size, now: entry.date)
            }
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
        OrbitStatusWidget()
        OrbitTodayWidget()
    }
}

#Preview("Medium", as: .systemMedium) {
    OrbitUsageWidget()
} timeline: {
    UsageEntry(date: .now, snapshot: .placeholder, options: .all)
}
