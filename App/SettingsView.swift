import SwiftUI
import WidgetKit

struct SettingsView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var refreshMinutes = AppSettings.refreshMinutes
    @State private var tokenMessage: String?
    @State private var manualToken = ""
    @State private var manualTokenSaved = ManualTokenStore.load() != nil
    @State private var manualMessage: String?

    private var sections: [(String, [SettingKey])] {
        var order: [String] = []
        var map: [String: [SettingKey]] = [:]
        for k in SettingKey.allCases {
            if map[k.section] == nil { order.append(k.section) }
            map[k.section, default: []].append(k)
        }
        return order.map { ($0, map[$0]!) }
    }

    @State private var tab = CommandLine.arguments.contains("--render-settings") ? 1 : 0

    var body: some View {
        TabView(selection: $tab) {
            displayTab.tabItem { Label("表示", systemImage: "switch.2") }.tag(0)
            styleTab.tabItem { Label("デザイン", systemImage: "paintpalette") }.tag(1)
            accountTab.tabItem { Label("接続", systemImage: "key") }.tag(2)
        }
        .frame(width: 520, height: 640)
    }

    private var displayTab: some View {
        Form {
            ForEach(sections, id: \.0) { section in
                if section.0 != "認証" {
                    Section(section.0) {
                        ForEach(section.1, id: \.self) { key in
                            Toggle(key.title, isOn: binding(key))
                        }
                    }
                }
            }
            Section("更新") {
                Stepper("取得間隔: \(refreshMinutes) 分", value: $refreshMinutes, in: 1...60)
                    .onChange(of: refreshMinutes) { _, v in AppSettings.refreshMinutes = v; store.settingsChanged() }
            }
        }
        .formStyle(.grouped)
    }

    var styleTab: some View { StylePreviewList().environmentObject(store) }
}

/// The "デザイン" tab: full-size medium previews of every style (scrollable).
struct StylePreviewList: View {
    var body: some View {
        ScrollView { StylePreviewContent() }
    }
}

/// The previews themselves — separate from the ScrollView so they can be rendered offscreen.
struct StylePreviewContent: View {
    @EnvironmentObject private var store: UsageStore

    private func options(with style: WidgetStyle) -> DisplayOptions {
        var o = store.options
        o.style = style
        return o
    }

    /// Medium-widget preview drawn at the real widget size (344×164, 18pt margins).
    private func preview(_ s: WidgetStyle, scale: CGFloat = 1.0) -> some View {
        UsageDashboardView(snapshot: .placeholder, options: options(with: s), size: .medium)
            .padding(18)
            .frame(width: 344, height: 164)
            .background(DashboardBackground(style: s, level: .aboveTarget))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .scaleEffect(scale)
            .frame(width: 344 * scale, height: 164 * scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ウィジェットとメニューバーの見た目").font(.headline)
            ForEach(WidgetStyle.allCases) { s in
                Button {
                    AppSettings.style = s
                    store.settingsChanged()
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        preview(s)
                        HStack(spacing: 6) {
                            Text(s.title).font(.system(.body, weight: .semibold))
                            if store.options.style == s { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                            Text(s.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .frame(width: 344)
                    }
                    .padding(10)
                    .frame(width: 344 + 20)
                    .background(store.options.style == s ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(store.options.style == s ? Color.accentColor : Color.clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
    }
}

extension SettingsView {
    private var accountTab: some View {
        Form {
            Section("手動トークン (上級者向け)") {
                Text(manualTokenSaved ? "保存済み — キーチェーンのトークンより優先して使います" : "未設定 — Claude Code のキーチェーン項目を使います")
                    .font(.caption).foregroundStyle(manualTokenSaved ? .green : .secondary)
                SecureField("user:profile スコープを持つ OAuth アクセストークン", text: $manualToken)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存して再取得") {
                        do {
                            try ManualTokenStore.save(manualToken)
                            manualTokenSaved = ManualTokenStore.load() != nil
                            manualToken = ""
                            manualMessage = "保存しました"
                            Task { await store.refresh(); manualMessage = store.snapshot.errorMessage ?? "取得 OK" }
                        } catch { manualMessage = "保存失敗: \(error.localizedDescription)" }
                    }
                    .disabled(manualToken.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("削除") {
                        ManualTokenStore.delete(); manualTokenSaved = false; manualMessage = "削除しました"
                        Task { await store.refresh() }
                    }
                    .disabled(!manualTokenSaved)
                    if let m = manualMessage { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Text("通常は不要です。ターミナルで `claude` を起動してログインすると、Claude Code がキーチェーンに保存するトークンを自動で使います。`claude setup-token` のトークンは user:profile スコープが無いため使えません (403)。API キー (sk-ant-api…) も不可です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code の認証情報 (自動検出)") {
                Text(store.credentialInfo).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("キーチェーンの「Claude Code-credentials」または ~/.claude/.credentials.json を読み取ります。トークンは Claude Code が更新するため、期限切れの場合は一度 `claude` を起動してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("トークン更新") {
                Toggle(SettingKey.autoRefreshToken.title, isOn: binding(.autoRefreshToken))
                Text("期限切れ時（約 8 時間ごと）に refresh token で更新し、Claude Code と同じキーチェーン項目に書き戻します。OFF にすると、ターミナルで `claude` を起動するまで使用量が止まります。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("今すぐ更新して再取得") {
                        Task {
                            await store.refresh(forceTokenRefresh: true)
                            tokenMessage = store.snapshot.errorMessage ?? "OK (\(store.snapshot.tokenState.rawValue))"
                        }
                    }
                    if let m = tokenMessage { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            Section("ウィジェットの追加") {
                Text("デスクトップを右クリック →「ウィジェットを編集」→ “Orbit for Claude Code” を追加。通知センターにも置けます。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("ウィジェットを再読み込み") { WidgetCenter.shared.reloadAllTimelines() }
            }
        }
        .formStyle(.grouped)
    }

    private func options(with style: WidgetStyle) -> DisplayOptions {
        var o = store.options
        o.style = style
        return o
    }

    private func binding(_ key: SettingKey) -> Binding<Bool> {
        Binding(get: { AppSettings.bool(key) }, set: { AppSettings.set(key, $0); store.settingsChanged() })
    }
}
