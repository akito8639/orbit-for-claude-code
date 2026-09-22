import SwiftUI
import WidgetKit

// MARK: - Palette

enum Palette {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)      // Claude terracotta
    static let ok = Color(red: 0.36, green: 0.85, blue: 0.55)
    static let warn = Color(red: 1.00, green: 0.70, blue: 0.25)
    static let bad = Color(red: 1.00, green: 0.38, blue: 0.40)
    static let track = Color.white.opacity(0.16)

    static func level(_ l: UsageLevel) -> Color {
        switch l {
        case .onTrack: return ok
        case .aboveTarget: return warn
        case .wellAboveTarget: return bad
        case .exhausted: return bad
        }
    }

    static func status(_ s: ServiceStatus?) -> Color {
        guard let s else { return .gray }
        if s.isHealthy { return ok }
        switch s.indicator {
        case "critical", "major": return bad
        default: return warn
        }
    }
}

enum DashboardSize { case small, medium, large }

extension View {
    /// Numeric text transition + interpolation between timeline entries (digits roll, value eases).
    func animatedNumber<V: Equatable>(_ value: V) -> some View {
        self.contentTransition(.numericText()).animation(.easeInOut(duration: 0.9), value: value)
    }
}

// MARK: - Root view

/// One view used by the widget (all families) and the menu bar window.
struct UsageDashboardView: View {
    var snapshot: UsageSnapshot
    var options: DisplayOptions
    var size: DashboardSize
    var now: Date = .now
    var inWidget: Bool = false
    var refreshable: Bool = false   // the fetched-at stamp (small: the header) is a refresh button — the live widget only

    var body: some View {
        switch options.style {
        case .glassOrbit: GlassOrbitView(snapshot: snapshot, options: options, size: size, now: now, inWidget: inWidget, refreshable: refreshable)
        case .paceBars: PaceBarsView(snapshot: snapshot, options: options, size: size, now: now, inWidget: inWidget, refreshable: refreshable)
        case .console: ConsoleView(snapshot: snapshot, options: options, size: size, now: now, inWidget: inWidget, refreshable: refreshable)
        }
    }
}

/// WidgetKit greys everything out while it waits for a new timeline — during a resize it re-renders an
/// archived entry this way, which reads as "the widget did not draw". Our placeholder is sample data, so
/// draw it properly; a privacy redaction (anything other than the placeholder) is left alone.
struct DrawPlaceholder: ViewModifier {
    @Environment(\.redactionReasons) private var reasons

    func body(content: Content) -> some View {
        if reasons == .placeholder { content.unredacted() } else { content }
    }
}

/// Background for each style; used by the widget's containerBackground and the app window.
struct DashboardBackground: View {
    var style: WidgetStyle
    var level: UsageLevel

    var body: some View {
        switch style {
        case .glassOrbit:
            ZStack {
                LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.18), Color(red: 0.16, green: 0.12, blue: 0.24)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Palette.level(level).opacity(0.35), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
                RadialGradient(colors: [Palette.claude.opacity(0.25), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 220)
            }
        case .paceBars:
            LinearGradient(colors: [Color(red: 0.27, green: 0.22, blue: 0.62), Color(red: 0.36, green: 0.20, blue: 0.58)], startPoint: .top, endPoint: .bottom)
        case .console:
            Color(red: 0.07, green: 0.08, blue: 0.09)
        }
    }
}

// MARK: - Shared pieces

struct RingView: View {
    var progress: Double        // 0...1
    var pace: Double?           // 0...1
    var color: Color
    var lineWidth: CGFloat
    var showPace: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Palette.track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.003, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
                .animation(.easeInOut(duration: 0.9), value: progress)   // grows from the previous value on each timeline update
            if showPace, let pace {
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 2, height: lineWidth + 4)
                    .offset(y: -0.5 * 0)
                    .modifier(RingTick(fraction: pace))
                    .animation(.easeInOut(duration: 0.9), value: pace)
            }
        }
    }
}

/// Places a tick on the ring's circumference at `fraction`.
private struct RingTick: ViewModifier {
    var fraction: Double
    func body(content: Content) -> some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            content
                .position(x: geo.size.width / 2, y: geo.size.height / 2 - r)
                .rotationEffect(.degrees(fraction * 360))
        }
    }
}

struct PaceBar: View {
    var utilization: Double     // 0...100
    var pace: Double?           // 0...1
    var color: Color
    var showMarker: Bool
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(color)
                    .frame(width: max(height, w * min(utilization, 100) / 100))
                    .widgetAccentable()
                    .animation(.easeInOut(duration: 0.9), value: utilization)
                if showMarker, let pace {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 2, height: height - 4)
                        .offset(x: max(1, min(w - 3, w * pace - 1)))
                        .animation(.easeInOut(duration: 0.9), value: pace)
                }
            }
        }
        .frame(height: height)
    }
}

struct Chip: View {
    var text: String
    var color: Color = .white.opacity(0.7)
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.white.opacity(0.12), in: Capsule())
    }
}

/// Service-status lamp. Widgets cannot run continuous animations, so an incident is shown with a
/// stronger glow and a halo; in the app (menu bar panel) the lamp really pulses.
struct StatusDot: View {
    var status: ServiceStatus?
    var pulsing: Bool = false
    @State private var on = false

    private var unhealthy: Bool { status.map { !$0.isHealthy } ?? false }

    var body: some View {
        let c = Palette.status(status)
        Circle().fill(c).frame(width: 7, height: 7)
            .shadow(color: c.opacity(unhealthy ? 1 : 0.8), radius: unhealthy ? 6 : 3)
            .overlay(
                Circle().stroke(c.opacity(unhealthy ? (pulsing ? (on ? 0.9 : 0.1) : 0.6) : 0), lineWidth: 2)
                    .frame(width: 13, height: 13)
            )
            .scaleEffect(pulsing && unhealthy ? (on ? 1.25 : 0.9) : 1)
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// Headline such as "Well above target — 85% of the week".
struct Headline {
    static func eyebrow(_ w: UsageWindow?, options: DisplayOptions) -> String {
        guard let w else { return L("NO DATA") }
        return L("WORST — CLAUDE %@", w.title.uppercased())
    }
    static func text(_ w: UsageWindow?, now: Date, options: DisplayOptions, snapshot: UsageSnapshot) -> String {
        if let err = snapshot.errorMessage, snapshot.windows.isEmpty { return err }
        guard let w else { return L("Waiting for data…") }
        let lvl = w.level(at: now)
        return "\(lvl.headline) — \(Fmt.percent(w.utilization)) \(w.unitLabel())"
    }
}

// MARK: - Extras row (status / sessions / today) shared by all styles

struct ExtrasRow: View {
    var snapshot: UsageSnapshot
    var options: DisplayOptions
    var compact: Bool = false
    var mono: Bool = false
    var pulsing: Bool = false
    var showStatusText: Bool = true   // false when the layout spells the status out elsewhere (console types it at the cursor); the lamp stays

    private var font: Font { mono ? .system(size: 10.5, design: .monospaced) : .system(size: 10.5, weight: .medium, design: .rounded) }

    /// Compact rows hide the status text while everything is operational; once it appears it is long
    /// ("Claude Code degraded performance"), so it gets a line of its own above the counts.
    private var showsStatusText: Bool { showStatusText && !(compact && (snapshot.serviceStatus?.isHealthy ?? false)) }

    var body: some View {
        Group {
            if compact && options[.showServiceStatus] && showsStatusText {
                VStack(alignment: .leading, spacing: 3) {
                    status
                    HStack(spacing: 8) { counts; Spacer(minLength: 0) }
                }
            } else {
                HStack(spacing: compact ? 8 : 12) {
                    if options[.showServiceStatus] { status }
                    counts
                    Spacer(minLength: 0)
                }
            }
        }
        .font(font)
        .foregroundStyle(.white.opacity(0.75))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var status: some View {
        HStack(spacing: 4) {
            StatusDot(status: snapshot.serviceStatus, pulsing: pulsing)
            if showsStatusText { Text(statusText).lineLimit(1) }
        }
    }

    @ViewBuilder private var counts: some View {
        if options[.showSessions] {
            HStack(spacing: 4) {
                Image(systemName: "terminal").font(.system(size: 9, weight: .bold))
                Text(L(snapshot.sessions.count == 1 ? "%d session" : "%d sessions", snapshot.sessions.count))
            }
            .fixedSize()
        }
        if options[.showTodayUsage], let t = snapshot.today {
            HStack(spacing: 4) {
                Image(systemName: "sum").font(.system(size: 9, weight: .bold))
                Text(compact ? Fmt.tokens(t.totalTokens) : L("today") + " " + Fmt.tokens(t.totalTokens) + String(format: " · $%.1f", t.estimatedCostUSD)).animatedNumber(t.totalTokens)
            }
            .fixedSize()
        }
    }

    private var statusText: String { snapshot.serviceStatus?.headline ?? L("status ?") }
}

/// Per-component status dots (claude.ai / API / Console / Claude Code / Cowork …), wrapping into rows.
struct ComponentGrid: View {
    var components: [ServiceStatus.StatusComponent]
    var mono: Bool

    private func color(_ st: String) -> Color {
        switch st {
        case "operational": return Palette.ok
        case "major_outage", "critical": return Palette.bad
        default: return Palette.warn
        }
    }

    var body: some View {
        let cols = [GridItem(.adaptive(minimum: 86), spacing: 6, alignment: .leading)]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 3) {
            ForEach(components) { c in
                HStack(spacing: 4) {
                    Circle().fill(color(c.status)).frame(width: 5, height: 5)
                    Text(c.shortName).lineLimit(1).minimumScaleFactor(0.8)
                    if !c.isOperational {
                        Text(c.status.replacingOccurrences(of: "_", with: " ")).foregroundStyle(color(c.status)).lineLimit(1)
                    }
                }
                .font(mono ? .system(size: 9.5, design: .monospaced) : .system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

/// Stacked bar of the weekly usage by surface (Claude Code / chat / Cowork / other).
struct BreakdownBar: View {
    var rows: [UsageSnapshot.BreakdownRow]
    var mono: Bool
    private let colors: [Color] = [Palette.claude, Color(red: 0.55, green: 0.65, blue: 1.0), Color(red: 0.45, green: 0.85, blue: 0.85), Color.white.opacity(0.35)]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        if r.percent > 0 {
                            Rectangle().fill(colors[i % colors.count]).frame(width: max(2, geo.size.width * r.percent / 100))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
                .animation(.easeInOut(duration: 0.9), value: rows)
            }
            .frame(height: 3)
            HStack(spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    if r.percent > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(colors[i % colors.count]).frame(width: 5, height: 5)
                            Text("\(r.displayName) \(Int(r.percent.rounded()))%").lineLimit(1).animatedNumber(r.percent)
                        }
                    }
                }
            }
            .font(mono ? .system(size: 9.5, design: .monospaced) : .system(size: 9.5, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// Detailed extras for the large widget / app window.
struct ExtrasDetail: View {
    var snapshot: UsageSnapshot
    var options: DisplayOptions
    var mono: Bool = false
    var now: Date = .now
    var maxSessionRows: Int = 1   // the usage widget shows only the most recently changed session; the Sessions widget lists them all
    var sessionsCompact: Bool = false   // true: one line (count + activity lamps), no session row

    /// Sessions ordered by their latest state change (falls back to start time).
    private var recentlyChanged: [LocalSession] {
        snapshot.sessions.sorted { ($0.statusUpdatedAt ?? $0.startedAt ?? .distantPast) > ($1.statusUpdatedAt ?? $1.startedAt ?? .distantPast) }
    }

    private var body1: Font { mono ? .system(size: 11, design: .monospaced) : .system(size: 11, weight: .medium, design: .rounded) }
    private var cap: Font { mono ? .system(size: 9.5, design: .monospaced) : .system(size: 9.5, weight: .semibold, design: .rounded) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if options[.showServiceStatus], let s = snapshot.serviceStatus {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("CLAUDE STATUS")).font(cap).tracking(1).foregroundStyle(.white.opacity(0.5))
                    HStack(spacing: 6) {
                        StatusDot(status: s)
                        Text(s.description).font(body1).lineLimit(1).minimumScaleFactor(0.8)
                        if let cc = s.claudeCodeStatus { Chip(text: (mono ? "code · " : "Claude Code · ") + cc.replacingOccurrences(of: "_", with: " ")) }
                    }
                    ForEach(s.unresolvedIncidents.prefix(2), id: \.self) { inc in
                        Text("• " + inc).font(cap).foregroundStyle(Palette.warn).lineLimit(1)
                    }
                    if options[.showAllComponents], !s.components.isEmpty {
                        ComponentGrid(components: s.components, mono: mono)
                    }
                }
            }
            if options[.showBreakdown], let rows = snapshot.breakdown, !rows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("WEEK BY SURFACE")).font(cap).tracking(1).foregroundStyle(.white.opacity(0.5))
                    BreakdownBar(rows: rows, mono: mono)
                }
            }
            if options[.showSessions], sessionsCompact {
                HStack(spacing: 6) {
                    Text(L("RUNNING SESSIONS") + " · \(snapshot.sessions.count)").font(cap).tracking(1).foregroundStyle(.white.opacity(0.5))
                    HStack(spacing: 3) {
                        ForEach(snapshot.sessions.prefix(8)) { s in ActivityLamp(activity: s.activity, size: 5) }
                    }
                }
            } else if options[.showSessions] {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L("RUNNING SESSIONS") + " · \(snapshot.sessions.count)").font(cap).tracking(1).foregroundStyle(.white.opacity(0.5))
                        HStack(spacing: 3) {
                            ForEach(snapshot.sessions.prefix(8)) { s in ActivityLamp(activity: s.activity, size: 5) }
                        }
                    }
                    if snapshot.sessions.isEmpty {
                        Text(L("none")).font(body1).foregroundStyle(.white.opacity(0.6))
                    }
                    // The large widget only has room for two rows; the count in the heading covers the rest.
                    ForEach(recentlyChanged.prefix(maxSessionRows)) { s in
                        HStack(spacing: 6) {
                            Image(systemName: "terminal").font(.system(size: 9, weight: .bold)).foregroundStyle(ActivityStyle.color(s.activity))
                            Text(s.displayName(options)).font(body1).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            if let st = s.startedAt { Text(Fmt.relative(st, now: now)).font(cap).foregroundStyle(.white.opacity(0.5)).lineLimit(1).fixedSize() }
                            if let v = s.version { Text("v\(v)").font(cap).foregroundStyle(.white.opacity(0.4)).lineLimit(1).fixedSize() }
                        }
                    }

                }
            }
            if options[.showTodayUsage], let t = snapshot.today {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("TODAY (LOCAL LOGS)")).font(cap).tracking(1).foregroundStyle(.white.opacity(0.5))
                    HStack(spacing: 10) {
                        stat(Fmt.tokens(t.totalTokens), L("tokens"))
                        stat(Fmt.tokens(t.outputTokens), "out")
                        stat(Fmt.tokens(t.cacheReadTokens), "cache")
                        stat("\(t.messages)", L("msgs"))
                        stat(Fmt.cost(t.estimatedCostUSD), L("API est."))
                    }
                }
            }
        }
        .foregroundStyle(.white.opacity(0.9))
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(body1.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).animatedNumber(v)
            Text(l).font(cap).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
    }
}

// MARK: - Style A: Glass Orbit

struct GlassOrbitView: View {
    var snapshot: UsageSnapshot
    var options: DisplayOptions
    var size: DashboardSize
    var now: Date
    var inWidget: Bool
    var refreshable: Bool = false
    var hideExtrasRow: Bool = false   // large embeds the medium block; the details below already carry this info

    private var windows: [UsageWindow] { options.visibleWindows(snapshot) }
    private var worst: UsageWindow? { snapshot.worstWindow(at: now, visible: Set(windows.map(\.id))) }
    private var five: UsageWindow? { windows.first { $0.kind == .fiveHour } }
    /// The weekly window that matters most (all-model week vs per-model caps such as Fable).
    private var week: UsageWindow? {
        let weekly = windows.filter { $0.kind == .sevenDay || $0.kind == .weeklyScoped || $0.kind == .sevenDayOpus || $0.kind == .sevenDaySonnet }
        return weekly.max { a, b in
            let la = a.level(at: now), lb = b.level(at: now)
            return la == lb ? a.utilization < b.utilization : la < lb
        }
    }

    var body: some View {
        switch size {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    // Concentric rings: outer = week, inner = 5h. `dualCenter` shows both percentages inside the ring (small widget).
    private func rings(diameter: CGFloat, dualCenter: Bool = false) -> some View {
        ZStack {
            if let week {
                RingView(progress: week.utilization / 100, pace: week.paceFraction(at: now), color: Palette.level(week.level(at: now)), lineWidth: diameter * 0.085, showPace: options[.showPaceMarker])
                    .frame(width: diameter, height: diameter)
            }
            if let five {
                RingView(progress: five.utilization / 100, pace: five.paceFraction(at: now), color: Palette.level(five.level(at: now)), lineWidth: diameter * 0.085, showPace: options[.showPaceMarker])
                    .frame(width: diameter * 0.72, height: diameter * 0.72)
            }
            if dualCenter {
                VStack(alignment: .trailing, spacing: -1) {
                    if let five {
                        HStack(alignment: .lastTextBaseline, spacing: 3) {
                            Text(Fmt.percent(five.utilization)).font(.system(size: diameter * 0.11, weight: .bold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(Palette.level(five.level(at: now))).animatedNumber(five.utilization)
                            Text("5h").font(.system(size: diameter * 0.075, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    if let week {
                        HStack(alignment: .lastTextBaseline, spacing: 3) {
                            Text(Fmt.percent(week.utilization)).font(.system(size: diameter * 0.15, weight: .bold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(Palette.level(week.level(at: now))).animatedNumber(week.utilization)
                            Text(week.scopeName ?? "wk").font(.system(size: diameter * 0.075, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                    }
                    if five == nil && week == nil {
                        Text(Fmt.percent(worst?.utilization ?? 0)).font(.system(size: diameter * 0.17, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                // Keep the text inside the clear area of the inner ring (inner ring = 0.72·d, stroke = 0.085·d each side).
                .frame(width: diameter * 0.50)
                .widgetAccentable()
            } else {
                VStack(spacing: -2) {
                    Text(Fmt.percent(worst?.utilization ?? 0))
                        .font(.system(size: diameter * 0.19, weight: .bold, design: .rounded)).monospacedDigit().animatedNumber(worst?.utilization ?? 0)
                    Text(worst?.title ?? "—").font(.system(size: diameter * 0.09, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                }
                .widgetAccentable()
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }

    private var small: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "asterisk").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.claude)
                Text("Claude").font(.system(size: 11, weight: .bold, design: .rounded))
                Spacer()
                RefreshStamp(text: nil, font: .system(size: 9), color: .white.opacity(0.5), refresh: refreshable)
            }
            Spacer(minLength: 8)
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                rings(diameter: d, dualCenter: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The status lamp takes the free corner to the right of the ring, its bottom on the ring's outer
                // edge (the stroke is centred on the circle, so that edge is half a line width below the frame).
                if options[.showServiceStatus] {
                    StatusDot(status: snapshot.serviceStatus)
                        .position(x: geo.size.width - 6, y: geo.size.height / 2 + d / 2 + d * 0.0425 - 3.5)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func legend(_ t: String, _ w: UsageWindow) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Palette.level(w.level(at: now))).frame(width: 6, height: 6)
            Text("\(t) \(Fmt.percent(w.utilization))").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.white.opacity(0.1), in: Capsule())
    }

    private var medium: some View {
        GeometryReader { geo in
        HStack(spacing: 14) {
            rings(diameter: min(106, geo.size.height), dualCenter: true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "asterisk").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.claude)
                    Text("Claude").font(.system(size: 13, weight: .bold, design: .rounded)).lineLimit(1)
                    if options[.showProfile], let p = snapshot.profile { Chip(text: p.planBadge).fixedSize() }
                    Spacer(minLength: 2)
                    RefreshStamp(text: Fmt.relative(snapshot.fetchedAt, now: now), font: .system(size: 9, design: .rounded), color: .white.opacity(0.5), refresh: refreshable)
                }
                Text(Headline.text(worst, now: now, options: options, snapshot: snapshot))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.level(worst?.level(at: now) ?? .onTrack))
                    .lineLimit(1).minimumScaleFactor(0.65).animatedNumber(worst?.utilization ?? 0)
                ForEach(windows.prefix(4)) { w in
                    row(w)
                }
                if options[.showExtraUsage], let e = snapshot.extraUsage, e.isEnabled, let u = e.utilization {
                    HStack(spacing: 6) {
                        Text(L("extra")).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.6)).frame(width: 52, alignment: .leading)
                        PaceBar(utilization: u, pace: nil, color: Palette.claude, showMarker: false, height: 6)
                        Text(Fmt.percent(u)).font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit().animatedNumber(u)
                    }
                }
                Spacer(minLength: 0)
                if !hideExtrasRow {
                    ExtrasRow(snapshot: snapshot, options: options, compact: true, pulsing: !inWidget)
                }
            }
        }
        }
        .foregroundStyle(.white)
    }

    private func row(_ w: UsageWindow) -> some View {
        HStack(spacing: 6) {
            Text(w.title).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.6)).frame(width: 44, alignment: .leading).lineLimit(1).minimumScaleFactor(0.7)
            PaceBar(utilization: w.utilization, pace: w.paceFraction(at: now), color: Palette.level(w.level(at: now)), showMarker: options[.showPaceMarker], height: 6)
            Text(Fmt.percent(w.utilization)).font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).frame(width: 34, alignment: .trailing).contentTransition(.numericText(value: w.utilization)).animation(.easeInOut(duration: 0.9), value: w.utilization)
            if options[.showResetTimes] {
                Text(Fmt.resetLabel(w.resetsAt, now: now)).font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.5)).frame(width: 50, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    private var large: some View {
        var top = self
        top.hideExtrasRow = true
        return VStack(alignment: .leading, spacing: 10) {
            top.medium.frame(height: 118).padding(.top, 4)
            Divider().overlay(Color.white.opacity(0.15))
            ExtrasDetail(snapshot: snapshot, options: options, now: now, sessionsCompact: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Style B: Pace Bars (reference screenshot)

struct PaceBarsView: View {
    var snapshot: UsageSnapshot
    var options: DisplayOptions
    var size: DashboardSize
    var now: Date
    var inWidget: Bool
    var refreshable: Bool = false

    private var windows: [UsageWindow] { options.visibleWindows(snapshot) }
    private var worst: UsageWindow? { snapshot.worstWindow(at: now, visible: Set(windows.map(\.id))) }
    private var worstLevel: UsageLevel { worst?.level(at: now) ?? .onTrack }

    var body: some View {
        switch size {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            RingView(progress: (worst?.utilization ?? 0) / 100, pace: worst?.paceFraction(at: now), color: Palette.level(worstLevel), lineWidth: 5, showPace: options[.showPaceMarker])
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(Headline.eyebrow(worst, options: options)).font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.2).foregroundStyle(.white.opacity(0.55))
                Text(Headline.text(worst, now: now, options: options, snapshot: snapshot))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.level(worstLevel))
                    .lineLimit(1).minimumScaleFactor(0.7).animatedNumber(worst?.utilization ?? 0)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.clockNow(now)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                RefreshStamp(text: Fmt.relative(snapshot.fetchedAt, now: now), font: .system(size: 9, design: .rounded), color: .white.opacity(0.55), refresh: refreshable)
            }
        }
    }

    private var providerLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "asterisk").font(.system(size: 12, weight: .bold))
            Text("Claude").font(.system(size: 15, weight: .bold, design: .rounded))
            if options[.showProfile], let p = snapshot.profile { Chip(text: p.planBadge) }
            Spacer()
            Text(worstLevel.label).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Palette.level(worstLevel))
        }
    }

    private func row(_ w: UsageWindow, barHeight: CGFloat = 12) -> some View {
        let lvl = w.level(at: now)
        return HStack(spacing: 8) {
            HStack(spacing: 3) {
                if w.id == worst?.id { Circle().fill(Palette.level(lvl)).frame(width: 4, height: 4) }
                Text(w.title).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            .frame(width: 62, alignment: .leading)
            PaceBar(utilization: w.utilization, pace: w.paceFraction(at: now), color: Palette.level(lvl), showMarker: options[.showPaceMarker], height: barHeight)
            Text(Fmt.percent(w.utilization)).font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).frame(width: 36, alignment: .trailing).contentTransition(.numericText(value: w.utilization)).animation(.easeInOut(duration: 0.9), value: w.utilization)
            if options[.showResetTimes] {
                Text(Fmt.resetLabel(w.resetsAt, now: now)).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.55)).frame(width: 56, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "asterisk").font(.system(size: 10, weight: .bold))
                Text("Claude").font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                RefreshStamp(text: nil, font: .system(size: 9), color: .white.opacity(0.55), refresh: refreshable)
                if options[.showServiceStatus] { StatusDot(status: snapshot.serviceStatus) }
            }
            Text(worstLevel.label).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Palette.level(worstLevel))
            ForEach(windows.prefix(3)) { w in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(w.title).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Text(Fmt.percent(w.utilization)).font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit().animatedNumber(w.utilization)
                    }
                    PaceBar(utilization: w.utilization, pace: w.paceFraction(at: now), color: Palette.level(w.level(at: now)), showMarker: options[.showPaceMarker], height: 8)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: windows.count >= 3 ? 4 : 6) {
            header
            Divider().overlay(Color.white.opacity(0.15))
            providerLine
            ForEach(windows.prefix(3)) { w in row(w) }
            if options[.showExtraUsage], let e = snapshot.extraUsage, e.isEnabled, let u = e.utilization {
                row(UsageWindow(id: "extra", kind: .other, utilization: u, resetsAt: nil))
            }
            Spacer(minLength: 0)
            if options[.showServiceStatus] || options[.showSessions] || options[.showTodayUsage] {
                ExtrasRow(snapshot: snapshot, options: options, compact: true, pulsing: !inWidget)
            }
        }
        .foregroundStyle(.white)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider().overlay(Color.white.opacity(0.15))
            providerLine
            ForEach(windows) { w in row(w, barHeight: 12) }
            if options[.showExtraUsage], let e = snapshot.extraUsage, e.isEnabled, let u = e.utilization {
                row(UsageWindow(id: "extra", kind: .other, utilization: u, resetsAt: nil), barHeight: 12)
            }
            Divider().overlay(Color.white.opacity(0.15))
            ExtrasDetail(snapshot: snapshot, options: options, now: now, sessionsCompact: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Style C: Console

struct ConsoleView: View {
    var snapshot: UsageSnapshot
    var options: DisplayOptions
    var size: DashboardSize
    var now: Date
    var inWidget: Bool
    var refreshable: Bool = false

    private var windows: [UsageWindow] { options.visibleWindows(snapshot) }
    private var worst: UsageWindow? { snapshot.worstWindow(at: now, visible: Set(windows.map(\.id))) }
    private var worstLevel: UsageLevel { worst?.level(at: now) ?? .onTrack }
    private let ink = Color(red: 0.86, green: 0.87, blue: 0.84)
    private let dim = Color(red: 0.86, green: 0.87, blue: 0.84).opacity(0.5)

    private func mono(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s, weight: w, design: .monospaced) }

    var body: some View {
        switch size {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    private var prompt: some View {
        HStack(spacing: 6) {
            Text("❯").font(mono(12, .bold)).foregroundStyle(Palette.claude)
            Text("claude").font(mono(12, .bold)).foregroundStyle(ink)
            Text("/usage").font(mono(12)).foregroundStyle(dim)
            if options[.showProfile], let p = snapshot.profile { Text("[\(p.planBadge.lowercased())]").font(mono(10)).foregroundStyle(dim) }
            Spacer()
            Text(Fmt.clockNow(now)).font(mono(11)).foregroundStyle(dim)
        }
    }

    private func line(_ w: UsageWindow, barHeight: CGFloat = 8) -> some View {
        let lvl = w.level(at: now)
        return HStack(spacing: 8) {
            Text(w.title.padding(toLength: 9, withPad: " ", startingAt: 0)).font(mono(11)).foregroundStyle(dim).lineLimit(1)
            PaceBar(utilization: w.utilization, pace: w.paceFraction(at: now), color: Palette.level(lvl), showMarker: options[.showPaceMarker], height: barHeight)
            Text(String(format: "%3d%%", Int(w.utilization.rounded()))).font(mono(11, .bold)).foregroundStyle(Palette.level(lvl)).monospacedDigit().animatedNumber(w.utilization)
            if options[.showResetTimes] {
                Text("↻" + Fmt.resetLabel(w.resetsAt, now: now)).font(mono(9.5)).foregroundStyle(dim).frame(width: 74, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 4) {
            Text("→").font(mono(11)).foregroundStyle(dim)
            Text(Headline.text(worst, now: now, options: options, snapshot: snapshot)).font(mono(11, .semibold)).foregroundStyle(Palette.level(worstLevel)).lineLimit(1).minimumScaleFactor(0.75).animatedNumber(worst?.utilization ?? 0)
        }
    }

    /// The status line the compact rows would show, when there is something to say (an incident).
    private var incident: String? {
        guard options[.showServiceStatus], let s = snapshot.serviceStatus, !s.isHealthy else { return nil }
        return s.headline
    }

    /// Idle prompt — or, during an incident, the status typed at the prompt as if it had just been entered.
    /// `typing` is off in large, where the status section below spells the same thing out.
    private func cursor(typing: Bool = true) -> some View {
        HStack(spacing: 6) {
            Text("❯").font(mono(12, .bold)).foregroundStyle(Palette.claude)
            if typing, let incident {
                Text(incident).font(mono(11)).foregroundStyle(Palette.status(snapshot.serviceStatus))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            RoundedRectangle(cornerRadius: 1).fill(ink.opacity(0.8)).frame(width: 7, height: 13)
            Spacer(minLength: 4)
            RefreshStamp(text: Fmt.relative(snapshot.fetchedAt, now: now), font: mono(9.5), color: dim, refresh: refreshable)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("❯").font(mono(11, .bold)).foregroundStyle(Palette.claude)
                Text("claude").font(mono(11, .bold)).foregroundStyle(ink)
                Spacer()
                RefreshStamp(text: nil, font: mono(9.5), color: dim, refresh: refreshable)
                if options[.showServiceStatus] { StatusDot(status: snapshot.serviceStatus) }
            }
            ForEach(windows.prefix(3)) { w in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(w.title).font(mono(10)).foregroundStyle(dim)
                        Spacer()
                        Text(Fmt.percent(w.utilization)).font(mono(11, .bold)).foregroundStyle(Palette.level(w.level(at: now))).animatedNumber(w.utilization)
                    }
                    PaceBar(utilization: w.utilization, pace: w.paceFraction(at: now), color: Palette.level(w.level(at: now)), showMarker: options[.showPaceMarker], height: 7)
                }
            }
            Spacer(minLength: 0)
            Text(worstLevel.label).font(mono(10, .semibold)).foregroundStyle(Palette.level(worstLevel))
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 5) {
            prompt
            ForEach(windows.prefix(3)) { w in line(w) }
            if options[.showExtraUsage], let e = snapshot.extraUsage, e.isEnabled, let u = e.utilization {
                line(UsageWindow(id: "extra", kind: .other, utilization: u, resetsAt: nil))
            }
            summary
            Spacer(minLength: 0)
            ExtrasRow(snapshot: snapshot, options: options, compact: true, mono: true, pulsing: !inWidget, showStatusText: incident == nil)
            cursor()
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 5) {
            prompt
            ForEach(windows) { w in line(w, barHeight: 9) }
            if options[.showExtraUsage], let e = snapshot.extraUsage, e.isEnabled, let u = e.utilization {
                line(UsageWindow(id: "extra", kind: .other, utilization: u, resetsAt: nil), barHeight: 10)
            }
            summary
            Rectangle().fill(dim.opacity(0.3)).frame(height: 1).padding(.vertical, 2)
            ExtrasDetail(snapshot: snapshot, options: options, mono: true, now: now)
            Spacer(minLength: 0)
            cursor(typing: false)
        }
    }
}
