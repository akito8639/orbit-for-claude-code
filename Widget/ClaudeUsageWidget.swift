import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    let options: DisplayOptions
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: .placeholder, options: AppSettings.snapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let snap = context.isPreview ? UsageSnapshot.placeholder : (SnapshotStore.load() ?? .placeholder)
        completion(UsageEntry(date: .now, snapshot: snap, options: AppSettings.snapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let options = AppSettings.snapshot()
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

@main
struct ClaudeUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppConstants.widgetKind, provider: UsageProvider()) { entry in
            ClaudeUsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Orbit for Claude Code")
        .description("5時間 / 週間の使用量、稼働状況、起動中セッションを表示します。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview("Medium", as: .systemMedium) {
    ClaudeUsageWidget()
} timeline: {
    UsageEntry(date: .now, snapshot: .placeholder, options: .all)
}
