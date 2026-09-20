import SwiftUI
import WidgetKit
import AppKit
import Combine

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    @Published var snapshot: UsageSnapshot = SnapshotStore.load() ?? UsageSnapshot(
        fetchedAt: .distantPast, windows: [], extraUsage: nil, profile: nil, serviceStatus: nil,
        sessions: [], today: nil, tokenState: .missing, errorMessage: "Fetching…")
    @Published var isRefreshing = false
    @Published var credentialInfo: String = "—"
    @Published var options: DisplayOptions = AppSettings.snapshot()

    private var timer: Timer?

    func start() {
        // No usage data yet (first run / no token): show settings right away, don't wait for the first fetch.
        if snapshot.windows.isEmpty { Self.openSettingsWindow() }
        Task { await refresh() }
        reschedule()
    }

    private static var settingsWindow: NSWindow?

    /// Opens (or brings forward) a dedicated settings window. Reliable for a menu-bar-only app.
    static func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingView(rootView: SettingsView().environmentObject(UsageStore.shared))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = L("Orbit for Claude Code — Settings")
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        settingsWindow = w
    }

    func reschedule() {
        timer?.invalidate()
        let interval = TimeInterval(AppSettings.refreshMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func settingsChanged() {
        options = AppSettings.snapshot()
        reschedule()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func refresh(forceTokenRefresh: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        options = AppSettings.snapshot()
        let report = await Collector.collect(options: options, forceTokenRefresh: forceTokenRefresh)
        snapshot = report.snapshot
        if let c = report.credentials {
            let where_ = c.service ?? c.fileURL?.path ?? "?"
            let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
            credentialInfo = "\(where_)\n\(c.subscriptionType ?? "?") / \(c.rateLimitTier ?? "?") · expires \(df.string(from: c.expiresAt))"
        } else {
            credentialInfo = "not found"
        }
        try? SnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UsageStore.shared.start()
    }

    /// URLs handed over by widget taps (`widgetURL` / `Link`).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.scheme {
            case "https", "http":
                NSWorkspace.shared.open(url)
            case "orbit":
                Self.handle(url)
            default:
                break
            }
        }
    }

    static func handle(_ url: URL) {
        let store = UsageStore.shared
        switch url.host {
        case "refresh":
            Task { await store.refresh() }
        case "settings":
            UsageStore.openSettingsWindow()
        case "sessions":
            activateClaudeApp()
        case "session":
            let id = url.lastPathComponent
            guard let s = store.snapshot.sessions.first(where: { $0.id == id }) else { activateClaudeApp(); return }
            if let link = s.deepLink {
                NSWorkspace.shared.open(link)              // opens that session in the Claude desktop app
            } else {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.cwd)   // CLI session → its folder
            }
        default:
            break
        }
    }

    static func activateClaudeApp() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = UsageStore.shared

    init() {
        // `Orbit --render out.png [--live]` writes a gallery of every style × size and exits (used for previews/docs).
        let args = CommandLine.arguments
        if args.contains("--reload") {
            WidgetCenter.shared.reloadAllTimelines()
            Thread.sleep(forTimeInterval: 1)
            exit(0)
        }
        if args.contains("--fetch") {
            // One-shot collection without starting the menu bar UI (used from scripts/tests). Add --refresh-token to refresh an expired token.
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let report = await Collector.collect(options: AppSettings.snapshot(), forceTokenRefresh: args.contains("--refresh-token"))
                try? SnapshotStore.save(report.snapshot)
                print(report.snapshot.errorMessage ?? "fetched \(report.snapshot.windows.count) windows")
                sem.signal()
            }
            sem.wait()
            WidgetCenter.shared.reloadAllTimelines()
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-settings"), i + 1 < args.count {
            let view = StylePreviewContent().environmentObject(UsageStore.shared).frame(width: 520).background(Color(nsColor: .windowBackgroundColor))
            let r = ImageRenderer(content: view); r.scale = 2
            if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[i + 1])); print("wrote settings")
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-extras"), i + 1 < args.count {
            let snap = args.contains("--live") ? (SnapshotStore.load() ?? .placeholder) : .placeholder
            Gallery.renderExtras(to: URL(fileURLWithPath: args[i + 1]), snapshot: snap)
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            Gallery.renderIcon(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-icon-bundle"), i + 1 < args.count {
            Gallery.renderIconBundle(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if args.contains("--raw") {
            print(SnapshotStore.load()?.rawUsageJSON ?? "(no usage response stored yet)")
            exit(0)
        }
        if args.contains("--sizes") {
            for (k, v) in AppSettings.defaults.dictionaryRepresentation() where k.hasPrefix("debug_") { print(k, v) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            let live = args.contains("--live")
            let snap = live ? (SnapshotStore.load() ?? .placeholder) : .placeholder
            Gallery.render(to: URL(fileURLWithPath: args[i + 1]), snapshot: snap)
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(store)
        } label: {
            MenuBarLabel(snapshot: store.snapshot, options: store.options)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

struct MenuBarLabel: View {
    var snapshot: UsageSnapshot
    var options: DisplayOptions

    var body: some View {
        let worst = snapshot.worstWindow(visible: Set(options.visibleWindows(snapshot).map(\.id)))
        HStack(spacing: 3) {
            Image(systemName: "asterisk")
            Text(worst.map { Fmt.percent($0.utilization) } ?? "Orbit").monospacedDigit()
        }
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject private var store: UsageStore
    @State private var now = Date.now
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var level: UsageLevel {
        store.snapshot.worstWindow(at: now, visible: Set(store.options.visibleWindows(store.snapshot).map(\.id)))?.level(at: now) ?? .onTrack
    }

    var body: some View {
        VStack(spacing: 10) {
            // Same layout and size as the Medium widget (344×164, 18pt content margins).
            UsageDashboardView(snapshot: store.snapshot, options: store.options, size: .medium, now: now)
                .padding(18)
                .frame(width: 344, height: 164)
                .background(DashboardBackground(style: store.options.style, level: level))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .glassEffect(.regular.tint(Palette.level(level).opacity(0.15)), in: .rect(cornerRadius: 22))

            if let err = store.snapshot.errorMessage {
                Text(err).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(width: 344, alignment: .leading)
            }

            VStack(spacing: 8) {
                Picker("", selection: Binding(get: { store.options.style }, set: { AppSettings.style = $0; store.settingsChanged() })) {
                    ForEach(WidgetStyle.allCases) { s in Text(s.title).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button { Task { await store.refresh() } } label: {
                            Label(store.isRefreshing ? L("Refreshing…") : L("Refresh"), systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing)
                        Spacer()
                        Button { UsageStore.openSettingsWindow() } label: { Image(systemName: "gearshape") }
                        Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    }
                    .buttonStyle(.glass)
                }
            }
            .frame(width: 344)
        }
        .padding(12)
        .onReceive(tick) { now = $0 }
    }
}
