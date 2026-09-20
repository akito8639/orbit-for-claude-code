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

    var projectName: String { (cwd as NSString).lastPathComponent }
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
                         context: ContextUsage(input: 1_200, cacheRead: 412_000, cacheCreation: 9_800, output: 900, model: "claude-fable-5-1", limit: 1_000_000, at: .now)),
            LocalSession(id: "2", pid: 2, cwd: "/Users/you/Development/website", startedAt: .now.addingTimeInterval(-4 * 3600), version: "2.1.275", entrypoint: "claude-desktop",
                         context: ContextUsage(input: 3_400, cacheRead: 156_000, cacheCreation: 2_100, output: 400, model: "claude-sonnet-5", limit: 200_000, at: .now)),
            LocalSession(id: "3", pid: 3, cwd: "/Users/you/Development/api-server", startedAt: .now.addingTimeInterval(-90), version: "2.1.275", entrypoint: "cli",
                         context: ContextUsage(input: 800, cacheRead: 38_000, cacheCreation: 12_000, output: 300, model: "claude-fable-5-1", limit: 1_000_000, at: .now)),
        ],
        today: LocalUsageToday(inputTokens: 120_000, outputTokens: 38_000, cacheCreationTokens: 410_000, cacheReadTokens: 2_900_000, messages: 212, estimatedCostUSD: 14.2,
                               byModel: ["claude-fable-5-1": 2_600_000, "claude-sonnet-5": 700_000, "claude-haiku-4-5-20251001": 168_000]),
        tokenState: .ok,
        errorMessage: nil,
        breakdown: [BreakdownRow(key: "claude_code", displayName: "Claude Code", percent: 92), BreakdownRow(key: "chat", displayName: "Chat", percent: 6), BreakdownRow(key: "cowork", displayName: "Cowork", percent: 2)]
    )

    /// The window with the worst level (ties broken by utilization).
    func worstWindow(at now: Date = .now, visible: Set<String>? = nil) -> UsageWindow? {
        let candidates = windows.filter { visible == nil || visible!.contains($0.id) }
        return candidates.max { a, b in
            let la = a.level(at: now), lb = b.level(at: now)
            return la == lb ? a.utilization < b.utilization : la < lb
        }
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

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
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
