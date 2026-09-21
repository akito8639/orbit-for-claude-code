import Foundation
import SwiftUI

enum WidgetStyle: String, CaseIterable, Identifiable, Codable {
    case glassOrbit
    case paceBars
    case console

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glassOrbit: return "Glass Orbit"
        case .paceBars: return "Pace Bars"
        case .console: return "Console"
        }
    }

    var subtitle: String {
        switch self {
        case .glassOrbit: return L("Liquid Glass rings — the macOS 27 look")
        case .paceBars: return L("Capsule bars with pace markers")
        case .console: return L("Terminal style — the Claude Code feel")
        }
    }
}

/// Feature toggles. Every displayable piece of information has a switch here.
enum SettingKey: String, CaseIterable {
    case showFiveHour = "show_five_hour"
    case showSevenDay = "show_seven_day"
    case showModelWindows = "show_model_windows"
    case showExtraUsage = "show_extra_usage"
    case showBreakdown = "show_breakdown"
    case showOtherWindows = "show_other_windows"
    case showPaceMarker = "show_pace_marker"
    case showProfile = "show_profile"
    case showServiceStatus = "show_service_status"
    case showAllComponents = "show_all_components"
    case showSessions = "show_sessions"
    case showTodayUsage = "show_today_usage"
    case showResetTimes = "show_reset_times"
    case forceEnglishWidgets = "force_english_widgets"
    case preferSessionNames = "prefer_session_names"
    case showCowork = "show_cowork"
    case launchAtLogin = "launch_at_login"
    case notifyLimits = "notify_limits"
    case notifyWaiting = "notify_waiting"
    case notifyIncidents = "notify_incidents"
    case autoRefreshToken = "auto_refresh_token"

    var defaultValue: Bool {
        switch self {
        case .showOtherWindows, .forceEnglishWidgets, .launchAtLogin: return false
        default: return true
        }
    }

    var title: String {
        switch self {
        case .showFiveHour: return L("5-hour window")
        case .showSevenDay: return L("Weekly window")
        case .showModelWindows: return L("Per-model weekly caps (Fable / Opus / Sonnet)")
        case .showBreakdown: return L("Weekly usage by surface (Claude Code / chat / Cowork)")
        case .showExtraUsage: return L("Extra usage credits")
        case .showOtherWindows: return L("Show other windows the API returns")
        case .showPaceMarker: return L("Pace target marker")
        case .showProfile: return L("Account (e-mail / plan)")
        case .showServiceStatus: return L("Claude service status (status.claude.com)")
        case .showAllComponents: return L("Per-component status (claude.ai / API / Console / Cowork…)")
        case .showSessions: return L("Running Claude Code sessions")
        case .showTodayUsage: return L("Today's tokens / API-equivalent cost")
        case .showResetTimes: return L("Reset times")
        case .forceEnglishWidgets: return L("Widgets always in English")
        case .preferSessionNames: return L("Show session titles instead of folder names")
        case .showCowork: return L("Cowork sessions (desktop app)")
        case .launchAtLogin: return L("Launch at login")
        case .notifyLimits: return L("Notify when a limit passes the threshold")
        case .notifyWaiting: return L("Notify when a session waits for you")
        case .notifyIncidents: return L("Notify when Claude has an incident and when it recovers")
        case .autoRefreshToken: return L("Refresh expired token automatically")
        }
    }

    var section: String {
        switch self {
        case .showFiveHour, .showSevenDay, .showModelWindows, .showExtraUsage, .showOtherWindows, .showPaceMarker, .showResetTimes, .showBreakdown:
            return L("Usage (OAuth usage API)")
        case .showProfile:
            return L("Account (OAuth profile API)")
        case .showServiceStatus, .showAllComponents:
            return L("Service status")
        case .showSessions, .showTodayUsage, .preferSessionNames, .showCowork:
            return L("Local (~/.claude)")
        case .forceEnglishWidgets:
            return L("Display")
        case .launchAtLogin:
            return L("Startup")
        case .notifyLimits, .notifyWaiting, .notifyIncidents:
            return L("Notifications")
        case .autoRefreshToken:
            return L("Authentication")
        }
    }
}

enum SessionSort: String, CaseIterable, Identifiable {
    case started      // newest session first
    case updated      // most recent state change first
    case name         // alphabetical
    var id: String { rawValue }
    var title: String {
        switch self {
        case .started: return L("Newest first")
        case .updated: return L("Latest change first")
        case .name: return L("By name")
        }
    }
}

struct AppSettings {
    static let defaults: UserDefaults = UserDefaults(suiteName: AppConstants.appGroupID) ?? .standard

    static let styleKey = "widget_style"
    static let refreshMinutesKey = "refresh_minutes"
    static let notifyThresholdKey = "notify_threshold"
    static let sessionSortKey = "session_sort"

    static var sessionSort: SessionSort {
        get { SessionSort(rawValue: defaults.string(forKey: sessionSortKey) ?? "") ?? .started }
        set { defaults.set(newValue.rawValue, forKey: sessionSortKey) }
    }

    static var notifyThreshold: Int {
        get { defaults.object(forKey: notifyThresholdKey) == nil ? 90 : defaults.integer(forKey: notifyThresholdKey) }
        set { defaults.set(newValue, forKey: notifyThresholdKey) }
    }

    static func bool(_ key: SettingKey) -> Bool {
        if defaults.object(forKey: key.rawValue) == nil { return key.defaultValue }
        return defaults.bool(forKey: key.rawValue)
    }

    static func set(_ key: SettingKey, _ value: Bool) {
        defaults.set(value, forKey: key.rawValue)
    }

    static var style: WidgetStyle {
        get { WidgetStyle(rawValue: defaults.string(forKey: styleKey) ?? "") ?? .glassOrbit }
        set { defaults.set(newValue.rawValue, forKey: styleKey) }
    }

    static var refreshMinutes: Int {
        get { max(1, defaults.object(forKey: refreshMinutesKey) == nil ? 5 : defaults.integer(forKey: refreshMinutesKey)) }
        set { defaults.set(newValue, forKey: refreshMinutesKey) }
    }

    /// Immutable copy used for rendering (widgets read it once per timeline).
    static func snapshot() -> DisplayOptions {
        var flags: [SettingKey: Bool] = [:]
        for k in SettingKey.allCases { flags[k] = bool(k) }
        return DisplayOptions(flags: flags, style: style, refreshMinutes: refreshMinutes, sessionSort: sessionSort)
    }
}

struct DisplayOptions: Hashable {
    var flags: [SettingKey: Bool]
    var style: WidgetStyle
    var refreshMinutes: Int
    var sessionSort: SessionSort = .started

    func sortedSessions(_ s: [LocalSession]) -> [LocalSession] {
        switch sessionSort {
        case .started: return s.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        case .updated: return s.sorted { ($0.statusUpdatedAt ?? $0.startedAt ?? .distantPast) > ($1.statusUpdatedAt ?? $1.startedAt ?? .distantPast) }
        case .name: return s.sorted { $0.displayName(self).localizedCaseInsensitiveCompare($1.displayName(self)) == .orderedAscending }
        }
    }

    subscript(_ key: SettingKey) -> Bool { flags[key] ?? key.defaultValue }

    static let all = DisplayOptions(flags: Dictionary(uniqueKeysWithValues: SettingKey.allCases.map { ($0, $0.defaultValue) }), style: .glassOrbit, refreshMinutes: 5)

    func isWindowVisible(_ w: UsageWindow) -> Bool {
        switch w.kind {
        case .fiveHour: return self[.showFiveHour]
        case .sevenDay: return self[.showSevenDay]
        case .sevenDayOpus, .sevenDaySonnet, .weeklyScoped: return self[.showModelWindows]
        case .sevenDayOAuthApps, .sevenDayCowork: return self[.showOtherWindows]
        case .other: return self[.showOtherWindows] && w.resetsAt != nil
        }
    }

    func visibleWindows(_ s: UsageSnapshot) -> [UsageWindow] {
        s.windows.filter(isWindowVisible)
    }

}
