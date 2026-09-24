import Foundation
import Security

// MARK: - Constants

enum AppConstants {
    /// App Group shared between app and widget. Read from the signed entitlements so the value lives only in Config.xcconfig.
    static let appGroupID: String = {
        if let task = SecTaskCreateFromSelf(nil),
           let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
           let first = groups.first {
            return first
        }
        return "com.akito.OrbitForClaudeCode"   // unsigned fallback (previews, tests)
    }()
    static let widgetKind = "OrbitWidget"
    static let widgetExecutable = "OrbitWidget"   // OrbitWidget.appex/Contents/MacOS/OrbitWidget — the process to end after an update
    static let snapshotFileName = "snapshot.json"
}

// MARK: - Usage windows

enum UsageWindowKind: String, Codable, CaseIterable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    case sevenDayOpus = "seven_day_opus"
    case sevenDaySonnet = "seven_day_sonnet"
    case sevenDayOAuthApps = "seven_day_oauth_apps"
    case sevenDayCowork = "seven_day_cowork"
    case weeklyScoped = "weekly_scoped"     // from the `limits` array: per-model weekly cap (e.g. Fable)
    case other

    var duration: TimeInterval {
        switch self {
        case .fiveHour: return 5 * 3600
        default: return 7 * 24 * 3600
        }
    }

    var shortTitle: String {
        switch self {
        case .fiveHour: return "5h"
        case .sevenDay: return "week"
        case .sevenDayOpus: return "opus wk"
        case .sevenDaySonnet: return "sonnet wk"
        case .sevenDayOAuthApps: return "apps wk"
        case .sevenDayCowork: return "cowork wk"
        case .weeklyScoped: return "model wk"
        case .other: return "other"
        }
    }
}

struct UsageWindow: Codable, Identifiable, Hashable {
    var id: String            // raw key from API (e.g. "five_hour")
    var kind: UsageWindowKind
    var utilization: Double   // 0...100
    var resetsAt: Date?
    var scopeName: String? = nil   // e.g. "Fable" for a per-model weekly cap
    var severity: String? = nil    // API-provided: normal / warning / …
    var isActive: Bool? = nil      // API-provided: this limit is the one currently constraining

    var title: String {
        if let scopeName { return "\(scopeName) wk" }
        return kind == .other ? id.replacingOccurrences(of: "_", with: " ") : kind.shortTitle
    }

    /// Name for pickers: "5-hour window" / "Weekly window" / "Fable weekly cap".
    var longTitle: String {
        switch kind {
        case .fiveHour: return L("5-hour window")
        case .sevenDay: return L("Weekly window")
        default: return scopeName.map { L("%@ weekly cap", $0) } ?? title
        }
    }

    /// "of the week" / "of the 5h" / "of the Fable week" — for the headline (localized).
    func unitLabel() -> String {
        switch kind {
        case .fiveHour: return L("of the 5h")
        default:
            if let scopeName { return L("of the %@ week", scopeName) }
            return L("of the week")
        }
    }

    /// Fraction of the window that has elapsed (0...1) — the "target" pace.
    func paceFraction(at now: Date = .now) -> Double? {
        guard let resetsAt else { return nil }
        let start = resetsAt.addingTimeInterval(-kind.duration)
        let f = now.timeIntervalSince(start) / kind.duration
        return min(max(f, 0), 1)
    }

    /// When the window reaches 100% if the average rate so far continues — the pace marker extended forward.
    /// Nil before the reset is known, early in the window (under 12% elapsed) or with too little use to tell.
    func projectedExhaustion(at now: Date = .now) -> Date? {
        guard let resetsAt, resetsAt > now, let f = paceFraction(at: now), f >= 0.12, utilization >= 3 else { return nil }
        let start = resetsAt.addingTimeInterval(-kind.duration)
        return start.addingTimeInterval(now.timeIntervalSince(start) * 100 / utilization)
    }

    /// A projected run-out this close to the reset is noise, not a warning.
    var forecastMargin: TimeInterval { kind == .fiveHour ? 20 * 60 : 3 * 3600 }

    /// "5h limit" / "weekly limit" / "Fable weekly limit" — for the forecast headline (localized).
    var limitName: String {
        switch kind {
        case .fiveHour: return L("5h limit")
        case .sevenDay: return L("weekly limit")
        default: return scopeName.map { L("%@ weekly limit", $0) } ?? L("%@ limit", title)
        }
    }

    func level(at now: Date = .now) -> UsageLevel {
        let computed = UsageLevel.classify(utilization: utilization, pace: paceFraction(at: now))
        // Let the API's own severity raise (never lower) the level.
        switch severity {
        case "warning": return max(computed, .aboveTarget)
        case "critical", "error", "blocked", "exceeded": return max(computed, .wellAboveTarget)
        default: return computed
        }
    }
}

enum UsageLevel: Int, Codable, Comparable {
    case onTrack = 0
    case aboveTarget = 1
    case wellAboveTarget = 2
    case exhausted = 3

    static func < (a: UsageLevel, b: UsageLevel) -> Bool { a.rawValue < b.rawValue }

    static func classify(utilization: Double, pace: Double?) -> UsageLevel {
        if utilization >= 100 { return .exhausted }
        guard let pace else {
            return utilization >= 90 ? .wellAboveTarget : utilization >= 70 ? .aboveTarget : .onTrack
        }
        let diff = utilization - pace * 100
        if diff >= 25 { return .wellAboveTarget }
        if diff >= 10 { return .aboveTarget }
        return .onTrack
    }

    /// Lowercase label ("above target"), localized.
    var label: String {
        switch self {
        case .onTrack: return L("on track")
        case .aboveTarget: return L("above target")
        case .wellAboveTarget: return L("well above target")
        case .exhausted: return L("limit reached")
        }
    }

    /// Sentence-case label for headlines ("Above target"), localized.
    var headline: String {
        switch self {
        case .onTrack: return L("On track")
        case .aboveTarget: return L("Above target")
        case .wellAboveTarget: return L("Well above target")
        case .exhausted: return L("Limit reached")
        }
    }
}

// MARK: - Forecast

/// The answer the headline gives instead of a number: when the binding limit runs out at this pace,
/// when it comes back, or that there is room until the reset.
struct UsageForecast: Equatable {
    enum Outcome: Equatable {
        case exhausted   // at the limit now; `date` is when it comes back
        case runsOut     // reaches the limit before its reset; `date` is when (projected)
        case lasts       // room to spare; `date` is the reset it lasts until
    }
    var outcome: Outcome
    var window: UsageWindow
    var date: Date?
    var level: UsageLevel

    func headline(now: Date = .now) -> String {
        switch outcome {
        case .exhausted: return L("%1$@ reached — back %2$@", window.limitName, Fmt.resetLabel(date, now: now))
        case .runsOut: return L("%1$@ ~%2$@ at this pace", window.limitName, date.map { Fmt.forecastLabel($0, now: now) } ?? "—")
        case .lasts:
            // "Room to spare" only when this pace ends the window well short of the limit; a tight finish just says it lasts.
            let atReset = window.utilization / max(window.paceFraction(at: now) ?? 1, 0.01)
            return L(atReset < 80 ? "Room to spare — lasts until %@" : "Lasts until %@ at this pace", Fmt.resetLabel(date, now: now))
        }
    }
}

// MARK: - Extra data

struct ExtraUsage: Codable, Hashable {
    var isEnabled: Bool
    var monthlyLimit: Double?
    var usedCredits: Double?
    var utilization: Double?
}

struct AccountProfile: Codable, Hashable {
    var email: String?
    var displayName: String?
    var organizationName: String?
    var subscriptionType: String?   // "max" / "pro" / ...
    var rateLimitTier: String?      // "default_claude_max_20x"

    var planBadge: String {
        let base = (subscriptionType ?? "").uppercased()
        if let tier = rateLimitTier, let range = tier.range(of: #"(\d+)x"#, options: .regularExpression) {
            return base.isEmpty ? String(tier[range]) : "\(base) \(tier[range])"
        }
        return base.isEmpty ? "—" : base
    }
}

struct ServiceStatus: Codable, Hashable {
    var indicator: String        // none / minor / major / critical / maintenance
    var description: String      // "All Systems Operational"
    var claudeCodeStatus: String? // component status: operational / degraded_performance / partial_outage / major_outage
    var unresolvedIncidents: [String]
    var updatedAt: Date?
    var components: [StatusComponent] = []   // every component on status.claude.com

    struct StatusComponent: Codable, Hashable, Identifiable {
        var name: String
        var status: String
        var id: String { name }
        var shortName: String {
            let n = name.replacingOccurrences(of: #"\s*\(.*\)"#, with: "", options: .regularExpression)
            if n == "Claude for Government" { return "Gov" }
            return n.replacingOccurrences(of: "Claude ", with: "")
        }
        var isOperational: Bool { status == "operational" }
    }

    var isHealthy: Bool { indicator == "none" && (claudeCodeStatus ?? "operational") == "operational" }

    /// One line for the widgets: the Claude Code component when it is the one in trouble, else the overall description.
    var headline: String {
        if let cc = claudeCodeStatus, cc != "operational" { return "Claude Code " + cc.replacingOccurrences(of: "_", with: " ") }
        return isHealthy ? L("operational") : description
    }
}

/// Context window of a session, taken from the last assistant record in its transcript.
struct ContextUsage: Codable, Hashable {
    var input: Int            // fresh input tokens of the last request
    var cacheRead: Int        // tokens served from the prompt cache
    var cacheCreation: Int    // tokens written to the cache this turn
    var output: Int
    var model: String
    var limit: Int            // 200_000 or 1_000_000, inferred from the model
    var at: Date?

    /// What the desktop app shows as "used": fresh input + cached prompt.
    var used: Int { input + cacheRead }
    var fraction: Double { min(1, Double(used) / Double(max(1, limit))) }
    var percent: Int { Int((Double(used) / Double(max(1, limit)) * 100).rounded()) }

    static func limit(for model: String, used: Int) -> Int {
        let m = model.lowercased()
        let oneM = m.contains("[1m]") || m.contains("fable") || m.contains("mythos") || m.contains("opus-5") || m.contains("sonnet-5")
        return (oneM || used > 200_000) ? 1_000_000 : 200_000
    }
}

struct LocalSession: Codable, Hashable, Identifiable {
    var id: String
    var pid: Int32
    var cwd: String
    var startedAt: Date?
    var version: String?
    var entrypoint: String?
    var context: ContextUsage? = nil
    var name: String? = nil          // title given in the desktop app (sessions/<pid>.json "name")
    var hostSessionId: String? = nil // desktop app session id ("local_…"), usable with claude://code/continue?session=
    var status: String? = nil        // written live by Claude Code: idle / busy / waiting
    var waitingFor: String? = nil    // "permission prompt" / "input needed" when status == waiting
    var statusUpdatedAt: Date? = nil

    /// SF Symbol for where the session was started (Claude Code's `entrypoint`).
    var entrypointSymbol: String {
        switch entrypoint ?? "" {
        case "cli", "terminal": return "terminal"
        case "claude-desktop", "claude-desktop-3p", "desktop": return "macwindow"
        case "claude-vscode", "vscode", "cursor", "windsurf", "zed", "jetbrains", "ide": return "chevron.left.forwardslash.chevron.right"
        case "sdk-ts", "sdk-py", "sdk-cli": return "shippingbox"
        case "local-agent", "cowork": return "person.2"
        case "remote", "web": return "cloud"
        case "slack", "claude-in-teams": return "bubble.left.and.bubble.right"
        case "github-action", "ci": return "gearshape.2"
        case "chrome": return "globe"
        default: return "questionmark.circle"
        }
    }

    enum Activity { case working, needsInput, permission, idle, unknown }
    var activity: Activity {
        switch status {
        case "busy": return .working
        case "waiting": return waitingFor?.contains("permission") == true ? .permission : .needsInput
        case "idle": return .idle
        default: return .unknown
        }
    }

    var projectName: String { (cwd as NSString).lastPathComponent }

    /// Tap target for this session: opens it in the Claude desktop app when it was started there.
    var deepLink: URL? {
        if let h = hostSessionId, h.hasPrefix("local_") {
            return URL(string: "claude://code/continue?session=\(h)&source=orbit")
        }
        return nil
    }

    /// Title when one exists and the setting allows it, otherwise the folder name.
    func displayName(_ options: DisplayOptions) -> String {
        if options[.preferSessionNames], let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        return projectName
    }
}

/// A Cowork session recorded by the Claude desktop app (local-agent-mode-sessions/<account>/<org>/local_*.json).
struct CoworkSession: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var createdAt: Date?
    var lastActivityAt: Date?
    var model: String?
    var isArchived: Bool
}

struct LocalUsageToday: Codable, Hashable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var messages: Int
    var estimatedCostUSD: Double
    var byModel: [String: Int]     // model -> total tokens

    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
}

enum TokenState: String, Codable {
    case ok
    case expired
    case missing
    case refreshed
}

// MARK: - Snapshot

struct UsageSnapshot: Codable {
    var fetchedAt: Date
    var windows: [UsageWindow]
    var extraUsage: ExtraUsage?
    var profile: AccountProfile?
    var serviceStatus: ServiceStatus?
    var sessions: [LocalSession]
    var today: LocalUsageToday?
    var tokenState: TokenState
    var errorMessage: String?
    var rawUsageJSON: String? = nil   // last raw usage response, for diagnostics (`ClaudeUsage --raw`)
    var breakdown: [BreakdownRow]? = nil   // seven_day_breakdown: share of the weekly usage per surface
    var coworkSessions: [CoworkSession]? = nil

    struct BreakdownRow: Codable, Hashable, Identifiable {
        var key: String
        var displayName: String
        var percent: Double
        var id: String { key }
    }

    static let placeholder = UsageSnapshot(
        fetchedAt: .now,
        windows: [
            UsageWindow(id: "five_hour", kind: .fiveHour, utilization: 15, resetsAt: .now.addingTimeInterval(3600 * 1.5)),
            UsageWindow(id: "seven_day", kind: .sevenDay, utilization: 85, resetsAt: .now.addingTimeInterval(3600 * 49)),
            UsageWindow(id: "weekly_scoped:Fable", kind: .weeklyScoped, utilization: 81, resetsAt: .now.addingTimeInterval(3600 * 49), scopeName: "Fable", severity: "warning", isActive: true),
        ],
        extraUsage: ExtraUsage(isEnabled: false, monthlyLimit: nil, usedCredits: nil, utilization: nil),
        profile: AccountProfile(email: "you@example.com", displayName: nil, organizationName: nil, subscriptionType: "max", rateLimitTier: "default_claude_max_20x"),
        serviceStatus: ServiceStatus(indicator: "none", description: "All Systems Operational", claudeCodeStatus: "operational", unresolvedIncidents: [], updatedAt: .now,
                                     components: ["claude.ai", "Claude Console (platform.claude.com)", "Claude API (api.anthropic.com)", "Claude Code", "Claude Cowork", "Claude for Government"].map { ServiceStatus.StatusComponent(name: $0, status: "operational") }),
        sessions: [
            LocalSession(id: "1", pid: 1, cwd: "/Users/you/Development/my-app", startedAt: .now.addingTimeInterval(-1800), version: "2.1.275", entrypoint: "cli",
                         context: ContextUsage(input: 1_200, cacheRead: 412_000, cacheCreation: 9_800, output: 900, model: "claude-fable-5-1", limit: 1_000_000, at: .now), name: "Onboarding flow rewrite", status: "busy", statusUpdatedAt: .now.addingTimeInterval(-40)),
            LocalSession(id: "2", pid: 2, cwd: "/Users/you/Development/website", startedAt: .now.addingTimeInterval(-4 * 3600), version: "2.1.275", entrypoint: "claude-desktop",
                         context: ContextUsage(input: 3_400, cacheRead: 156_000, cacheCreation: 2_100, output: 400, model: "claude-sonnet-5", limit: 200_000, at: .now), name: "Landing page copy", status: "waiting", waitingFor: "permission prompt", statusUpdatedAt: .now.addingTimeInterval(-120)),
            LocalSession(id: "3", pid: 3, cwd: "/Users/you/Development/api-server", startedAt: .now.addingTimeInterval(-90), version: "2.1.275", entrypoint: "cli",
                         context: ContextUsage(input: 800, cacheRead: 38_000, cacheCreation: 12_000, output: 300, model: "claude-fable-5-1", limit: 1_000_000, at: .now), status: "idle", statusUpdatedAt: .now.addingTimeInterval(-900)),
        ],
        today: LocalUsageToday(inputTokens: 120_000, outputTokens: 38_000, cacheCreationTokens: 410_000, cacheReadTokens: 2_900_000, messages: 212, estimatedCostUSD: 14.2,
                               byModel: ["claude-fable-5-1": 2_600_000, "claude-sonnet-5": 700_000, "claude-haiku-4-5-20251001": 168_000]),
        tokenState: .ok,
        errorMessage: nil,
        breakdown: [BreakdownRow(key: "claude_code", displayName: "Claude Code", percent: 92), BreakdownRow(key: "chat", displayName: "Chat", percent: 6), BreakdownRow(key: "cowork", displayName: "Cowork", percent: 2)],
        coworkSessions: [
            CoworkSession(id: "c1", title: "Quarterly report draft", createdAt: .now.addingTimeInterval(-7200), lastActivityAt: .now.addingTimeInterval(-600), model: "claude-fable-5-1", isArchived: false),
            CoworkSession(id: "c2", title: "Photo dialogue feature design", createdAt: .now.addingTimeInterval(-3 * 86400), lastActivityAt: .now.addingTimeInterval(-86400), model: "claude-sonnet-5", isArchived: false),
            CoworkSession(id: "c3", title: "Contract review", createdAt: .now.addingTimeInterval(-9 * 86400), lastActivityAt: .now.addingTimeInterval(-8 * 86400), model: "claude-fable-5-1", isArchived: false),
        ]
    )

    /// The window with the worst level (ties broken by utilization).
    func worstWindow(at now: Date = .now, visible: Set<String>? = nil) -> UsageWindow? {
        let candidates = windows.filter { visible == nil || visible!.contains($0.id) }
        return candidates.max { a, b in
            let la = a.level(at: now), lb = b.level(at: now)
            return la == lb ? a.utilization < b.utilization : la < lb
        }
    }

    /// The headline's answer across the visible windows; nil when there is not enough to go on yet.
    func forecast(at now: Date = .now, visible: Set<String>? = nil) -> UsageForecast? {
        let candidates = windows.filter { (visible == nil || visible!.contains($0.id)) && $0.resetsAt != nil }
        // Blocked: the answer is when the last exhausted limit comes back.
        if let w = candidates.filter({ $0.utilization >= 100 }).max(by: { $0.resetsAt! < $1.resetsAt! }) {
            return UsageForecast(outcome: .exhausted, window: w, date: w.resetsAt, level: .exhausted)
        }
        // The limit that runs out first, counting only run-outs well ahead of that window's own reset.
        let runOuts = candidates.compactMap { w -> (UsageWindow, Date)? in
            guard let t = w.projectedExhaustion(at: now), let r = w.resetsAt, r.timeIntervalSince(t) >= w.forecastMargin else { return nil }
            return (w, t)
        }
        if let (w, t) = runOuts.min(by: { $0.1 < $1.1 }) {
            return UsageForecast(outcome: .runsOut, window: w, date: t, level: t.timeIntervalSince(now) < 24 * 3600 ? .wellAboveTarget : .aboveTarget)
        }
        // Room to spare until the reset of the tightest weekly window; the 5-hour one resets too soon to be the answer.
        let projected = { (w: UsageWindow) in w.utilization / max(w.paceFraction(at: now) ?? 1, 0.01) }
        guard let w = candidates.filter({ $0.kind != .fiveHour && $0.projectedExhaustion(at: now) != nil }).max(by: { projected($0) < projected($1) })
        else { return nil }
        return UsageForecast(outcome: .lasts, window: w, date: w.resetsAt, level: .onTrack)
    }
}

// MARK: - Snapshot store (App Group container)

enum SnapshotStore {
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
    }

    static var fileURL: URL? {
        containerURL?.appendingPathComponent(AppConstants.snapshotFileName)
    }

    static func load() -> UsageSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(UsageSnapshot.self, from: data)
    }

    static func save(_ snapshot: UsageSnapshot) throws {
        guard let url = fileURL else { throw NSError(domain: "Orbit", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable"]) }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(snapshot).write(to: url, options: .atomic)
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static func resetLabel(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "—" }
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = L10n.locale
        if cal.isDate(date, inSameDayAs: now) {
            df.dateFormat = "HH:mm"
        } else if date.timeIntervalSince(now) < 6 * 86400 {
            df.dateFormat = "E HH:mm"
        } else {
            df.dateFormat = "MMM d HH:mm"
        }
        return df.string(from: date)
    }

    /// A projected time, rounded so it claims no more precision than it has: to the hour, or to 10 minutes within the next two hours.
    static func forecastLabel(_ date: Date, now: Date = .now) -> String {
        let step: TimeInterval = date.timeIntervalSince(now) < 2 * 3600 ? 600 : 3600
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: date))   // round on the local clock (half-hour zones)
        var t = ((date.timeIntervalSinceReferenceDate + offset) / step).rounded() * step - offset
        if t < now.timeIntervalSinceReferenceDate { t += step }
        return resetLabel(Date(timeIntervalSinceReferenceDate: t), now: now)
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return L("just now") }
        if s < 3600 { return L("%dm ago", s / 60) }
        if s < 86400 { return L("%dh ago", s / 3600) }
        return L("%dd ago", s / 86400)
    }

    /// "12m", "1h 05m", "2d 3h"
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60) }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }

    /// "878K", "33.3M", "232M" — one decimal only while it still fits a stat cell.
    static func tokens(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.0fM", Double(n) / 1_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    /// "$14.20", "$145" — cents are dropped once the estimate reaches three figures.
    static func cost(_ usd: Double) -> String {
        usd >= 100 ? String(format: "$%.0f", usd) : String(format: "$%.2f", usd)
    }

    static func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    /// "564.1k", "1M", "200k" — the desktop app's context-window style.
    static func ctx(_ n: Int) -> String {
        if n >= 1_000_000 { return n % 1_000_000 == 0 ? "\(n / 1_000_000)M" : String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return n % 1_000 == 0 ? "\(n / 1_000)k" : String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    static func clockNow(_ now: Date = .now) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df.string(from: now)
    }
}
