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
            displayTab.tabItem { Label(L("Display"), systemImage: "switch.2") }.tag(0)
            styleTab.tabItem { Label(L("Design"), systemImage: "paintpalette") }.tag(1)
            accountTab.tabItem { Label(L("Connection"), systemImage: "key") }.tag(2)
        }
        .frame(width: 520, height: 640)
    }

    private var displayTab: some View {
        Form {
            ForEach(sections, id: \.0) { section in
                if section.0 != L("Authentication") {
                    Section(section.0) {
                        ForEach(section.1, id: \.self) { key in
                            Toggle(key.title, isOn: binding(key))
                        }
                    }
                }
            }
            Section(L("Sessions") + " · " + L("Sort order")) {
                Picker(L("Sort order"), selection: Binding(get: { AppSettings.sessionSort }, set: { AppSettings.sessionSort = $0; store.settingsChanged() })) {
                    ForEach(SessionSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section(L("Notifications") + " · " + L("Threshold")) {
                Picker(L("Notify at"), selection: Binding(get: { AppSettings.notifyThreshold }, set: { AppSettings.notifyThreshold = $0; store.settingsChanged() })) {
                    ForEach([70, 80, 90, 95, 100], id: \.self) { Text("\($0)%").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section(L("Refresh")) {
                Stepper(L("Fetch interval: %d min", refreshMinutes), value: $refreshMinutes, in: 1...60)
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
            Text(L("Widget and menu bar appearance")).font(.headline)
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
            Section(L("Manual token (advanced)")) {
                Text(manualTokenSaved ? L("Saved — used instead of the keychain token") : L("Not set — using Claude Code's keychain item"))
                    .font(.caption).foregroundStyle(manualTokenSaved ? .green : .secondary)
                SecureField(L("OAuth access token with the user:profile scope"), text: $manualToken)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(L("Save and fetch")) {
                        do {
                            try ManualTokenStore.save(manualToken)
                            manualTokenSaved = ManualTokenStore.load() != nil
                            manualToken = ""
                            manualMessage = L("Saved")
                            Task { await store.refresh(manual: true); manualMessage = store.snapshot.errorMessage ?? L("Fetched OK") }
                        } catch { manualMessage = L("Save failed: %@", error.localizedDescription) }
                    }
                    .disabled(manualToken.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(L("Delete")) {
                        ManualTokenStore.delete(); manualTokenSaved = false; manualMessage = L("Deleted")
                        Task { await store.refresh(manual: true) }
                    }
                    .disabled(!manualTokenSaved)
                    if let m = manualMessage { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Text(L("Usually not needed. Log in with `claude` in a terminal and the token Claude Code stores in the keychain is used automatically. Tokens from `claude setup-token` lack the user:profile scope (403) and API keys (sk-ant-api…) cannot read plan limits."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Claude Code credentials (auto-detected)")) {
                Text(store.credentialInfo).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(L("Reads the keychain item “Claude Code-credentials” or ~/.claude/.credentials.json. Claude Code refreshes this token itself; if it has expired, run `claude` once."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Token refresh")) {
                Toggle(SettingKey.autoRefreshToken.title, isOn: binding(.autoRefreshToken))
                Text(L("When the token expires (about every 8 hours) it is refreshed with the refresh token and written back to the same keychain item Claude Code uses. If off, usage stops updating until you run `claude` in a terminal."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L("Refresh now and fetch")) {
                        Task {
                            await store.refresh(forceTokenRefresh: true, manual: true)
                            tokenMessage = store.snapshot.errorMessage ?? "OK (\(store.snapshot.tokenState.rawValue))"
                        }
                    }
                    if let m = tokenMessage { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            Section(L("Add the widget")) {
                Text(L("Right-click the desktop → “Edit Widgets” → add “Orbit for Claude Code”. It also works in Notification Center."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Reload widgets")) { WidgetCenter.shared.reloadAllTimelines() }
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
