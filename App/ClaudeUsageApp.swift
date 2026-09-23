import SwiftUI
import WidgetKit
import AppKit
import Combine
import ServiceManagement
import Sparkle

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
    private var sessionTimer: Timer?

    // WidgetKit gives each widget only ~40–70 reloads a day, and a menu bar app never counts as "in the foreground"
    // (the case that is exempt). Reloading every kind after every fetch and every session poll used that budget up
    // within hours; from then on WidgetKit deferred the reloads and the widgets — the sessions list most visibly —
    // stopped following the fresh snapshot on disk. So: reload a kind only when what it draws changed, and coalesce.
    private var widgetFingerprints: [String: Int] = [:]
    private var widgetReloadedAt: [String: Date] = [:]
    private var widgetReloadPending: Set<String> = []
    private var settingsPublish: Task<Void, Never>?   // debounces a run of settings changes into one forced reload
    private static let widgetMinReloadInterval: TimeInterval = 30
    private static let widgetMaxAge: TimeInterval = 45 * 60   // re-render anyway so "Nm ago" cannot drift for hours

    func start() {
        Notifier.shared.prepare()
        // Cheap poll of ~/.claude/sessions so the activity lamps follow Claude Code within ~30 s (poll + coalesced widget reload).
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { await self?.pollSessions() }
        }
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
        // Called from Toggle/Picker binding setters, i.e. during a view update: publish on the next run-loop turn.
        Task { @MainActor in
            options = AppSettings.snapshot()
            reschedule()
            Self.syncLoginItem(options[.launchAtLogin])
            Notifier.shared.prepare()
            // The user is watching the widgets while they flip a switch or pick a design: reload straight away
            // instead of waiting out the coalescing window the background polls need. A short settle keeps a run
            // of switches down to one reload.
            settingsPublish?.cancel()
            settingsPublish = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                self?.publishWidgets(force: true)
            }
        }
    }

    /// Reloads each widget kind whose content (snapshot slice + display options) differs from what it last rendered.
    /// `force` reloads every kind regardless (a refresh the user asked for should visibly land on all widgets).
    func publishWidgets(force: Bool = false) {
        let o = options, s = snapshot
        var h = Hasher(); h.combine(o)
        let base = h.finalize()
        func fp(_ parts: AnyHashable...) -> Int { var h = Hasher(); h.combine(base); for p in parts { h.combine(p) }; return h.finalize() }
        // Rounded the way the views draw them: resets_at carries server-side microsecond jitter, utilization is shown as a whole percent.
        let windows = s.windows.map { w -> [AnyHashable] in
            [w.id, Int(w.utilization.rounded()), w.resetsAt.map { Int($0.timeIntervalSinceReferenceDate / 60) } ?? -1, w.scopeName, w.severity, w.isActive]
        }
        // Sessions reload the widgets for a session appearing/going, a title change or "waiting for you" — not for the
        // busy⇄idle lamp, which flips several times per turn and would burn the budget by itself; the context figure
        // is coarse (10-point steps) for the same reason. The refresh button in the sessions widget shows the exact state.
        let sessions = s.sessions.map { [$0.id, $0.name, $0.activity == .needsInput || $0.activity == .permission, ($0.context?.percent ?? -10) / 10,
                                         $0.startedAt.map { Int($0.timeIntervalSinceReferenceDate / 60) }] as [AnyHashable] }
        let today = s.today.map { [Fmt.tokens($0.totalTokens), String(format: "%.1f", $0.estimatedCostUSD), $0.byModel] as [AnyHashable] }
        let status = s.serviceStatus.map { [$0.indicator, $0.description, $0.claudeCodeStatus, $0.unresolvedIncidents, $0.components] as [AnyHashable] }
        reloadWidget(AppConstants.widgetKind, fingerprint: fp(windows, s.extraUsage, s.profile, s.breakdown, status, sessions, today, s.tokenState, s.errorMessage), force: force)
        reloadWidget("OrbitSessionsWidget", fingerprint: fp(sessions, s.sessions.first?.version), force: force)
        reloadWidget("OrbitCoworkWidget", fingerprint: fp(s.coworkSessions), force: force)
        reloadWidget("OrbitStatusWidget", fingerprint: fp(status, s.serviceStatus?.updatedAt.map { Int($0.timeIntervalSinceReferenceDate / 60) }), force: force)
        reloadWidget("OrbitTodayWidget", fingerprint: fp(today), force: force)
    }

    private func reloadWidget(_ kind: String, fingerprint: Int, force: Bool) {
        let changed = widgetFingerprints[kind] != fingerprint
        widgetFingerprints[kind] = fingerprint
        let age = Date.now.timeIntervalSince(widgetReloadedAt[kind] ?? .distantPast)
        guard force || changed || age > Self.widgetMaxAge, !widgetReloadPending.contains(kind) else { return }   // a queued reload renders the latest snapshot anyway
        widgetReloadPending.insert(kind)
        Task { @MainActor in
            let wait = force ? 0 : Self.widgetMinReloadInterval - age
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            widgetReloadPending.remove(kind)
            widgetReloadedAt[kind] = .now
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }

    /// Registers/unregisters the app as a login item (System Settings → General → Login Items).
    static func syncLoginItem(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled { try service.register() }
            if !enabled, service.status == .enabled { try service.unregister() }
        } catch {
            NSLog("Orbit: login item change failed: %@", error.localizedDescription)
        }
    }

    /// A session that has just appeared is held back until its transcript yields a context figure, so the list never
    /// shows a row without its context bar that then jumps once the figure arrives. Sessions already listed stay listed.
    private static func admitting(_ fresh: [LocalSession], previouslyListed: [LocalSession]) -> [LocalSession] {
        fresh.filter { s in s.context != nil || previouslyListed.contains { $0.id == s.id } }
    }

    /// Re-reads session status/name (no transcript parsing for known sessions); keeps the context numbers from the
    /// last full refresh. A new session reads its transcript tail right away so it can be admitted with its bar.
    func pollSessions() async {
        guard !isRefreshing, options[.showSessions] else { return }
        let old = snapshot.sessions
        let fresh = await Task.detached(priority: .utility) {
            LocalScanner.runningSessions(includeContext: false).map { s -> LocalSession in
                var m = s
                m.context = old.first { $0.id == s.id }?.context ?? LocalScanner.contextUsage(sessionId: s.id, cwd: s.cwd)
                return m
            }
        }.value
        let merged = Self.admitting(fresh, previouslyListed: old)
        let changed = merged.map { "\($0.id)|\($0.status ?? "")|\($0.waitingFor ?? "")|\($0.name ?? "")" } != old.map { "\($0.id)|\($0.status ?? "")|\($0.waitingFor ?? "")|\($0.name ?? "")" }
        guard changed else { return }
        let previous = snapshot
        snapshot.sessions = merged
        Notifier.shared.evaluate(old: previous, new: snapshot, options: options)
        try? SnapshotStore.save(snapshot)
        publishWidgets()
    }

    /// `manual`: the user asked for it (menu, widget tap, settings) — every widget is reloaded, not only the changed ones.
    func refresh(forceTokenRefresh: Bool = false, manual: Bool = false) async {
        if isRefreshing {
            // A fetch is already running (the timer's, most likely). A manual request rides on it instead of being
            // dropped: wait for it, then make sure every widget shows its result.
            guard manual else { return }
            while isRefreshing { try? await Task.sleep(for: .milliseconds(200)) }
            publishWidgets(force: true)
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        options = AppSettings.snapshot()
        let report = await Collector.collect(options: options, forceTokenRefresh: forceTokenRefresh)
        let previous = snapshot
        snapshot = report.snapshot
        snapshot.sessions = Self.admitting(report.snapshot.sessions, previouslyListed: previous.sessions)
        Notifier.shared.evaluate(old: previous, new: snapshot, options: options)
        if let c = report.credentials {
            let where_ = c.service ?? c.fileURL?.path ?? "?"
            let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
            credentialInfo = "\(where_)\n\(c.subscriptionType ?? "?") / \(c.rateLimitTier ?? "?") · expires \(df.string(from: c.expiresAt))"
        } else {
            credentialInfo = "not found"
        }
        try? SnapshotStore.save(snapshot)
        publishWidgets(force: manual)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sparkle: checks the appcast on GitHub Releases once a day (asks the user once before enabling).
    static let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Self.updater
        Self.restartWidgetsAfterUpdate()
        UsageStore.shared.start()
    }

    /// A widget extension keeps running the code it was launched with. After an in-place update (Sparkle or
    /// `brew upgrade`) the desktop therefore keeps drawing the previous version's widgets — for days, until
    /// something restarts the extension. Do it once, on the first launch of a version we have not run before;
    /// chronod respawns the extension from the new bundle when it next needs a widget.
    static func restartWidgetsAfterUpdate() {
        let key = "last_launched_version"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let previous = AppSettings.defaults.string(forKey: key)
        AppSettings.defaults.set(version, forKey: key)
        guard previous != version else { return }   // no record either: an older version, or a fresh install where the kill is a no-op
        restartWidgets()
    }

    /// Ends the widget extension so the next render comes from the installed bundle, then asks for new timelines.
    static func restartWidgets() {
        _ = try? Shell.run("/usr/bin/killall", [AppConstants.widgetExecutable])
        WidgetCenter.shared.reloadAllTimelines()
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
            Task { await store.refresh(manual: true) }
        case "settings":
            UsageStore.openSettingsWindow()
        case "sessions", "cowork":
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
        // `--style glassOrbit|paceBars|console` forces a design for the render flags below.
        if let i = args.firstIndex(of: "--style"), i + 1 < args.count, let st = WidgetStyle(rawValue: args[i + 1]) {
            AppSettings.style = st
        }
        if let i = args.firstIndex(of: "--render-panel"), i + 1 < args.count {
            let snap = args.contains("--live") ? (SnapshotStore.load() ?? .placeholder) : .placeholder
            Gallery.renderPanel(to: URL(fileURLWithPath: args[i + 1]), snapshot: snap)
            exit(0)
        }
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
            Gallery.renderExtras(to: URL(fileURLWithPath: args[i + 1]), snapshot: Self.renderSnapshot(args))
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
        if args.contains("--sessions") {
            for s in LocalScanner.runningSessions(includeContext: false) {
                print("\(s.projectName) | name=\(s.name ?? "-") | status=\(s.status ?? "-") | waitingFor=\(s.waitingFor ?? "-") | host=\(s.hostSessionId ?? "-")")
            }
            exit(0)
        }
        if args.contains("--shared-token") {
            if let e = SharedToken.load() { print("shared token present, expires \(e.expiresAt)") } else { print("no shared token") }
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
            Gallery.render(to: URL(fileURLWithPath: args[i + 1]), snapshot: Self.renderSnapshot(args))
            exit(0)
        }
    }

    /// Snapshot for the `--render*` flags: `--live` uses the last fetched one, `--incident` previews the incident styling.
    private static func renderSnapshot(_ args: [String]) -> UsageSnapshot {
        var snap = args.contains("--live") ? (SnapshotStore.load() ?? .placeholder) : .placeholder
        if args.contains("--incident") {
            snap.serviceStatus = ServiceStatus(indicator: "major", description: "Partial outage", claudeCodeStatus: "degraded_performance",
                unresolvedIncidents: ["Elevated error rates for Claude Code"], updatedAt: .now,
                components: ["claude.ai", "Claude Console (platform.claude.com)", "Claude API (api.anthropic.com)", "Claude Code", "Claude Cowork", "Claude for Government"]
                    .map { ServiceStatus.StatusComponent(name: $0, status: $0 == "Claude Code" ? "degraded_performance" : "operational") })
        }
        return snap
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu().environmentObject(store)
        } label: {
            MenuBarLabel(snapshot: store.snapshot, options: store.options)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

struct MenuBarLabel: View {
    var snapshot: UsageSnapshot
    var options: DisplayOptions

    var body: some View {
        let shown = options.menuBarWindow(snapshot)
        // Label is what MenuBarExtra lays out correctly (icon + title on one baseline); inline images get dropped.
        let incident = (snapshot.serviceStatus.map { !$0.isHealthy } ?? false) && options[.showServiceStatus]
        let title = (shown.map { Fmt.percent($0.utilization) } ?? "Orbit") + (incident ? " ⚠︎" : "")
        // The menu bar defaults to icon-only for Labels; ask for both, on one baseline.
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "asterisk").font(.system(size: 12, weight: .semibold))
            Text(title).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
    }
}

/// Minimal menu: design switch, refresh, settings, quit. Everything else lives in the widgets.
struct MenuBarMenu: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        Picker(L("Design"), selection: Binding(get: { store.options.style }, set: { AppSettings.style = $0; store.settingsChanged() })) {
            ForEach(WidgetStyle.allCases) { s in Text(s.title).tag(s) }
        }
        Menu(L("Notifications")) {
            Toggle(L("Limit threshold (%d%%)", AppSettings.notifyThreshold), isOn: toggle(.notifyLimits))
            Toggle(L("Session waiting for you"), isOn: toggle(.notifyWaiting))
            Toggle(L("Claude incidents and recovery"), isOn: toggle(.notifyIncidents))
        }
        Button(store.isRefreshing ? L("Refreshing…") : L("Refresh")) { Task { await store.refresh(manual: true) } }
            .disabled(store.isRefreshing)
            .keyboardShortcut("r")
        Divider()
        Button(L("Check for Updates…")) { AppDelegate.updater.checkForUpdates(nil) }
        Button(L("Settings…")) { UsageStore.openSettingsWindow() }
            .keyboardShortcut(",")
        Button(L("Quit Orbit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func toggle(_ key: SettingKey) -> Binding<Bool> {
        Binding(get: { store.options[key] }, set: { AppSettings.set(key, $0); store.settingsChanged() })
    }
}
