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
        case .glassOrbit: return "Liquid Glass のリング。macOS 27 らしい質感"
        case .paceBars: return "参考画像に近いカプセルバー＋ペースマーカー"
        case .console: return "ターミナル風。Claude Code の空気感"
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
    case labelsJapanese = "labels_japanese"
    case autoRefreshToken = "auto_refresh_token"

    var defaultValue: Bool {
        switch self {
        case .labelsJapanese, .showOtherWindows: return false
        default: return true
        }
    }

    var title: String {
        switch self {
        case .showFiveHour: return "5時間ウィンドウ"
        case .showSevenDay: return "週間ウィンドウ"
        case .showModelWindows: return "モデル別の週間枠 (Fable / Opus / Sonnet)"
        case .showBreakdown: return "週間使用量の内訳 (Claude Code / チャット / Cowork)"
        case .showExtraUsage: return "追加クレジット (Extra usage)"
        case .showOtherWindows: return "API が返すその他の枠を自動表示"
        case .showPaceMarker: return "ペース目標マーカー"
        case .showProfile: return "アカウント (メール / プラン)"
        case .showServiceStatus: return "Claude 稼働状況 (status.claude.com)"
        case .showAllComponents: return "コンポーネント別の状態 (claude.ai / API / Console / Cowork…)"
        case .showSessions: return "起動中の Claude Code セッション"
        case .showTodayUsage: return "今日のトークン量 / API 換算コスト"
        case .showResetTimes: return "リセット時刻"
        case .labelsJapanese: return "ラベルを日本語にする"
        case .autoRefreshToken: return "期限切れトークンを自動更新"
        }
    }

    var section: String {
        switch self {
        case .showFiveHour, .showSevenDay, .showModelWindows, .showExtraUsage, .showOtherWindows, .showPaceMarker, .showResetTimes, .showBreakdown:
            return "使用量 (OAuth usage API)"
        case .showProfile:
            return "アカウント (OAuth profile API)"
        case .showServiceStatus, .showAllComponents:
            return "稼働状況"
        case .showSessions, .showTodayUsage:
            return "ローカル (~/.claude)"
        case .labelsJapanese:
            return "表示"
        case .autoRefreshToken:
            return "認証"
        }
    }
}

struct AppSettings {
    static let defaults: UserDefaults = UserDefaults(suiteName: AppConstants.appGroupID) ?? .standard

    static let styleKey = "widget_style"
    static let refreshMinutesKey = "refresh_minutes"

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
        return DisplayOptions(flags: flags, style: style, refreshMinutes: refreshMinutes)
    }
}

struct DisplayOptions: Hashable {
    var flags: [SettingKey: Bool]
    var style: WidgetStyle
    var refreshMinutes: Int

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

    func label(_ en: String, _ ja: String) -> String { self[.labelsJapanese] ? ja : en }
}
