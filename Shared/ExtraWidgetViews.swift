import SwiftUI
import WidgetKit

// Views for the secondary widgets (Sessions / Status / Today). They share the style setting
// (background and typeface) with the usage widget so several widgets side by side look like one set.

private struct StyleFonts {
    let mono: Bool
    init(_ style: WidgetStyle) { mono = style == .console }
    func body(_ size: CGFloat, _ w: Font.Weight = .medium) -> Font { mono ? .system(size: size, weight: w, design: .monospaced) : .system(size: size, weight: w, design: .rounded) }
    func cap(_ size: CGFloat = 9.5) -> Font { mono ? .system(size: size, design: .monospaced) : .system(size: size, weight: .semibold, design: .rounded) }
}

private struct WidgetHeader: View {
    var icon: String
    var title: String
    var trailing: String?
    var fonts: StyleFonts
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.claude)
            Text(title).font(fonts.body(12, .bold)).lineLimit(1)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(fonts.cap()).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Sessions

struct SessionsWidgetView: View {
    var snapshot: UsageSnapshot
    var options: DisplayOptions
    var size: DashboardSize
    var now: Date = .now

    private var fonts: StyleFonts { StyleFonts(options.style) }
    private var sessions: [LocalSession] { snapshot.sessions }

    var body: some View {
        VStack(alignment: .leading, spacing: size == .small ? 4 : 6) {
            WidgetHeader(icon: "terminal", title: L("Sessions"), trailing: size == .small ? nil : Fmt.relative(snapshot.fetchedAt, now: now), fonts: fonts)
            if sessions.isEmpty {
                Spacer(minLength: 0)
                Text(L("No running sessions")).font(fonts.body(11)).foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
            } else if size == .small {
                Spacer(minLength: 0)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(sessions.count)").font(fonts.body(34, .bold)).monospacedDigit()
                    Text(L(sessions.count == 1 ? "session" : "sessions")).font(fonts.cap(10)).foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(.white)
                ForEach(sessions.prefix(2)) { s in
                    HStack(spacing: 4) {
                        Circle().fill(Palette.ok).frame(width: 5, height: 5)
                        Text(s.displayName(options)).font(fonts.body(10)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).truncationMode(.middle)
                    }
                }
                if sessions.count > 2 { Text(L("+%d more", sessions.count - 2)).font(fonts.cap(9)).foregroundStyle(.white.opacity(0.5)) }
                Spacer(minLength: 0)
            } else {
                let maxRows = size == .large ? 6 : 4
                ForEach(sessions.prefix(maxRows)) { s in row(s) }
                if sessions.count > maxRows { Text(L("+%d more", sessions.count - maxRows)).font(fonts.cap()).foregroundStyle(.white.opacity(0.5)) }
                Spacer(minLength: 0)
                if size == .large {
                    Text(L("%d sessions", sessions.count) + " · " + L("Claude Code v%@", sessions.first?.version ?? "?"))
                        .font(fonts.cap()).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                }
            }
        }
    }

    private func row(_ s: LocalSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(Palette.ok).frame(width: 6, height: 6).shadow(color: Palette.ok.opacity(0.7), radius: 2)
                Text(s.displayName(options)).font(fonts.body(11.5, .semibold)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if size == .medium, let c = s.context {
                    Text("\(c.percent)%").font(fonts.cap()).foregroundStyle(.white.opacity(0.75)).monospacedDigit().lineLimit(1).fixedSize()
                }
                if size == .large, let e = s.entrypoint {
                    Chip(text: e == "claude-desktop" ? L("desktop") : L("cli"))
                }
                if let st = s.startedAt { Text(Fmt.duration(now.timeIntervalSince(st))).font(fonts.cap()).foregroundStyle(.white.opacity(0.55)).lineLimit(1).fixedSize() }
            }
            if size == .large, let c = s.context {
                // Second line: model and the desktop-style "566.4k / 1M (57%)"
                HStack(spacing: 6) {
                    Text(TodayWidgetView.shortModel(c.model)).font(fonts.cap(9.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(Fmt.ctx(c.used)) / \(Fmt.ctx(c.limit)) (\(c.percent)%)")
                        .font(fonts.cap(9.5)).foregroundStyle(.white.opacity(0.8)).monospacedDigit().lineLimit(1).fixedSize()
                }
                .padding(.leading, 12)
            }
            if let c = s.context {
                ContextBar(context: c, height: size == .large ? 6 : 4).padding(.leading, size == .large ? 12 : 0)
            }
        }
    }
}

/// Context-window bar: cached prompt (blue), cache writes (green), fresh input (orange) over the model's limit.
struct ContextBar: View {
    var context: ContextUsage
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let lim = Double(max(1, context.limit))
            HStack(spacing: 1) {
                seg(Color(red: 0.36, green: 0.58, blue: 1.0), Double(context.cacheRead) / lim * w)
                seg(Palette.ok, Double(context.cacheCreation) / lim * w)
                seg(Palette.claude, Double(context.input) / lim * w)
                Spacer(minLength: 0)
            }
            .frame(width: w)
            .background(Palette.track)
            .clipShape(Capsule())
        }
        .frame(height: height)
    }

    private func seg(_ color: Color, _ width: CGFloat) -> some View {
        Rectangle().fill(color).frame(width: max(0, width))
    }
}

// MARK: - Status

struct StatusWidgetView: View {
    var snapshot: UsageSnapshot
    var options: DisplayOptions
    var size: DashboardSize
    var now: Date = .now

    private var fonts: StyleFonts { StyleFonts(options.style) }
    private var status: ServiceStatus? { snapshot.serviceStatus }

    private var headline: String {
        guard let s = status else { return L("status ?") }
        return s.isHealthy ? L("All systems operational") : s.description
    }

    /// One word for the small widget: Operational / Degraded / Outage / Maintenance.
    private var shortWord: String {
        guard let s = status else { return "—" }
        if s.isHealthy { return L("Operational") }
        switch s.indicator {
        case "critical", "major": return L("Outage")
        case "maintenance": return L("Maintenance")
        default: return L("Degraded")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: size == .small ? 4 : 6) {
            WidgetHeader(icon: "waveform.path.ecg", title: size == .small ? L("Status") : L("Claude status"), trailing: size == .small ? nil : status?.updatedAt.map { Fmt.relative($0, now: now) }, fonts: fonts)
            if size == .small {
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    Circle().fill(Palette.status(status)).frame(width: 34, height: 34)
                        .shadow(color: Palette.status(status).opacity(0.8), radius: 10)
                        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    Text(shortWord).font(fonts.body(14, .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                if let s = status, !s.components.isEmpty {
                    let ok = s.components.filter(\.isOperational).count
                    HStack(spacing: 4) {
                        ForEach(s.components) { c in
                            Circle().fill(c.isOperational ? Palette.ok : Palette.warn).frame(width: 5, height: 5)
                        }
                        Spacer(minLength: 2)
                        Text(L("%d/%d operational", ok, s.components.count)).font(fonts.cap(9)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    StatusDot(status: status)
                    Text(headline).font(fonts.body(12, .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                }
                if let s = status, !s.components.isEmpty {
                    ComponentGrid(components: s.components, mono: fonts.mono)
                }
                if let s = status, !s.unresolvedIncidents.isEmpty {
                    ForEach(s.unresolvedIncidents.prefix(size == .large ? 6 : 1), id: \.self) { inc in
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Palette.warn)
                            Text(inc).font(fonts.cap()).foregroundStyle(Palette.warn).lineLimit(size == .large ? 2 : 1)
                        }
                    }
                } else if size == .large {
                    Text(L("No unresolved incidents")).font(fonts.cap()).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
                Text("status.claude.com").font(fonts.cap(9)).foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}

// MARK: - Today

struct TodayWidgetView: View {
    var snapshot: UsageSnapshot
    var options: DisplayOptions
    var size: DashboardSize
    var now: Date = .now

    private var fonts: StyleFonts { StyleFonts(options.style) }
    private var today: LocalUsageToday? { snapshot.today }

    private var models: [(String, Int)] {
        (today?.byModel ?? [:]).sorted { $0.value > $1.value }.map { (Self.shortModel($0.key), $0.value) }
    }

    static func shortModel(_ id: String) -> String {
        // "claude-opus-4-5-20251101" → "opus 4.5", "claude-fable-5-1" → "fable 5.1"
        var s = id.lowercased().replacingOccurrences(of: "claude-", with: "")
        s = s.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        let parts = s.split(separator: "-").map(String.init)
        guard let name = parts.first else { return id }
        let ver = parts.dropFirst().filter { Int($0) != nil }.joined(separator: ".")
        return ver.isEmpty ? name : "\(name) \(ver)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: size == .small ? 4 : 6) {
            WidgetHeader(icon: "sum", title: L("Today"), trailing: size == .small ? nil : Fmt.relative(snapshot.fetchedAt, now: now), fonts: fonts)
            if let t = today {
                if size == .small {
                    Spacer(minLength: 0)
                    Text(Fmt.tokens(t.totalTokens)).font(fonts.body(30, .bold)).monospacedDigit().foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                    Text(L("tokens")).font(fonts.cap(10)).foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 0)
                    HStack {
                        Text(String(format: "$%.2f", t.estimatedCostUSD)).font(fonts.body(12, .semibold)).foregroundStyle(Palette.claude)
                        Spacer()
                        Text("\(t.messages) " + L("msgs")).font(fonts.cap()).foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    HStack(spacing: 12) {
                        stat(Fmt.tokens(t.totalTokens), L("tokens"), big: true)
                        stat(Fmt.tokens(t.inputTokens), "in")
                        stat(Fmt.tokens(t.outputTokens), "out")
                        stat(Fmt.tokens(t.cacheReadTokens), "cache")
                        stat("\(t.messages)", L("msgs"))
                        Spacer(minLength: 0)
                        stat(String(format: "$%.2f", t.estimatedCostUSD), L("API est."), accent: true)
                    }
                    if !models.isEmpty {
                        let maxRows = size == .large ? 8 : 3
                        let total = max(1, t.totalTokens)
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(models.prefix(maxRows), id: \.0) { m in
                                HStack(spacing: 6) {
                                    Text(m.0).font(fonts.cap()).foregroundStyle(.white.opacity(0.7)).frame(width: 64, alignment: .leading).lineLimit(1)
                                    PaceBar(utilization: Double(m.1) / Double(total) * 100, pace: nil, color: Palette.claude, showMarker: false, height: 5)
                                    Text(Fmt.tokens(m.1)).font(fonts.cap()).foregroundStyle(.white.opacity(0.8)).frame(width: 44, alignment: .trailing)
                                }
                            }
                        }
                    }
                    if size == .large {
                        let cacheRatio = t.inputTokens + t.cacheReadTokens + t.cacheCreationTokens > 0
                            ? Double(t.cacheReadTokens) / Double(t.inputTokens + t.cacheReadTokens + t.cacheCreationTokens) * 100 : 0
                        HStack(spacing: 10) {
                            stat(Fmt.percent(cacheRatio), L("cache hit"))
                            stat(Fmt.tokens(t.cacheCreationTokens), L("cache write"))
                        }
                    }
                    Spacer(minLength: 0)
                    Text(L("From ~/.claude logs · estimate at API prices")).font(fonts.cap(9)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                }
            } else {
                Spacer(minLength: 0)
                Text(L("No usage yet today")).font(fonts.body(11)).foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
            }
        }
    }

    private func stat(_ v: String, _ l: String, big: Bool = false, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(fonts.body(big ? 16 : 12, .bold)).monospacedDigit().foregroundStyle(accent ? Palette.claude : .white).lineLimit(1)
            Text(l).font(fonts.cap(9)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
    }
}
