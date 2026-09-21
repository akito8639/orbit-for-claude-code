import SwiftUI
import AppKit

/// Offscreen render of every style × widget size — for design review and README screenshots.
enum Gallery {
    static let sizes: [(DashboardSize, CGSize)] = [
        // Real macOS 27 widget sizes (measured via TimelineProviderContext.displaySize); system content margin = 18pt.
        (.small, CGSize(width: 164, height: 164)),
        (.medium, CGSize(width: 344, height: 164)),
        (.large, CGSize(width: 344, height: 344)),
    ]

    @MainActor
    static func render(to url: URL, snapshot: UsageSnapshot) {
        var opts = DisplayOptions.all
        let view = VStack(alignment: .leading, spacing: 28) {
            ForEach(WidgetStyle.allCases) { style in
                let _ = { opts.style = style }()
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(style.title) — \(style.subtitle)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(Array(sizes.enumerated()), id: \.offset) { _, item in
                            let (size, dim) = item
                            let level = snapshot.worstWindow()?.level() ?? .onTrack
                            UsageDashboardView(snapshot: snapshot, options: opts, size: size, inWidget: true)
                                .padding(18)
                                .frame(width: dim.width, height: dim.height)
                                .background(DashboardBackground(style: style, level: level))
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
                                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                        }
                    }
                }
            }
        }
        .padding(36)
        .background(
            LinearGradient(colors: [Color(red: 0.12, green: 0.55, blue: 0.75), Color(red: 0.46, green: 0.32, blue: 0.80), Color(red: 0.95, green: 0.55, blue: 0.40)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
            return
        }
        try? png.write(to: url)
        print("wrote \(url.path)")
    }
}

// MARK: - Menu bar panel mock (for the README)

extension Gallery {
    @MainActor
    static func renderPanel(to url: URL, snapshot: UsageSnapshot) {
        let opts = AppSettings.snapshot()
        let level = snapshot.worstWindow()?.level() ?? .onTrack
        let view = VStack(spacing: 10) {
            UsageDashboardView(snapshot: snapshot, options: opts, size: .medium)
                .padding(18)
                .frame(width: 344, height: 164)
                .background(DashboardBackground(style: opts.style, level: level))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
            HStack(spacing: 0) {
                ForEach(WidgetStyle.allCases) { s in
                    Text(s.title).font(.system(size: 12, weight: .medium))
                        .padding(.vertical, 5).frame(maxWidth: .infinity)
                        .background(s == opts.style ? Color.white.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(2).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Label(L("Refresh"), systemImage: "arrow.clockwise").font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.12), in: Capsule())
                Spacer()
                Image(systemName: "gearshape").padding(8).background(Color.white.opacity(0.12), in: Circle())
                Image(systemName: "power").padding(8).background(Color.white.opacity(0.12), in: Circle())
            }
            .font(.system(size: 12))
        }
        .frame(width: 344)
        .padding(12)
        .foregroundStyle(.white)
        .background(Color(red: 0.13, green: 0.13, blue: 0.16).opacity(0.96), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 1))
        .padding(30)
        .background(LinearGradient(colors: [Color(red: 0.12, green: 0.55, blue: 0.75), Color(red: 0.46, green: 0.32, blue: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        print("wrote \(url.path)")
    }
}

// MARK: - Secondary widgets gallery

extension Gallery {
    @MainActor
    static func renderExtras(to url: URL, snapshot: UsageSnapshot) {
        let opts = AppSettings.snapshot()
        let rows: [(String, Int, (DashboardSize) -> AnyView)] = [
            ("Sessions", 3, { AnyView(SessionsWidgetView(snapshot: snapshot, options: opts, size: $0, linksEnabled: false)) }),
            ("Cowork", 3, { AnyView(CoworkWidgetView(snapshot: snapshot, options: opts, size: $0)) }),
            ("Claude status", 2, { AnyView(StatusWidgetView(snapshot: snapshot, options: opts, size: $0)) }),
            ("Today", 2, { AnyView(TodayWidgetView(snapshot: snapshot, options: opts, size: $0)) }),
        ]
        let view = VStack(alignment: .leading, spacing: 28) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 10) {
                    Text(row.0).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(Array(sizes.prefix(row.1).enumerated()), id: \.offset) { _, item in
                            let (size, dim) = item
                            let alert = row.0 == "Claude status" && (snapshot.serviceStatus.map { !$0.isHealthy } ?? false)
                            row.2(size)
                                .padding(18)
                                .frame(width: dim.width, height: dim.height)
                                .background(DashboardBackground(style: opts.style, level: alert ? .wellAboveTarget : .onTrack))
                                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(alert ? Palette.status(snapshot.serviceStatus) : .clear, lineWidth: 3).padding(1))
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
                                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                        }
                    }
                }
            }
        }
        .padding(36)
        .background(LinearGradient(colors: [Color(red: 0.12, green: 0.55, blue: 0.75), Color(red: 0.46, green: 0.32, blue: 0.80), Color(red: 0.95, green: 0.55, blue: 0.40)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        print("wrote \(url.path)")
    }
}

// MARK: - App icon

/// The app icon: two orbits (week outside, 5h inside) with a pace tick and a "planet" at the head of the outer orbit.
/// Rendered at 1024×1024 with `--render-icon`; macOS 26 applies its own glass treatment on top.
struct OrbitIconView: View {
    enum Layer { case all, back, front }   // Icon Composer layers: back = orbits, front = planet + asterisk
    var size: CGFloat = 1024
    var layer: Layer = .all

    var body: some View {
        let inset = size * 0.10                       // Apple's macOS icon grid: artwork ≈ 80% of the canvas
        let side = size - inset * 2
        let radius = side * 0.2237                    // continuous-corner squircle like system icons
        let outer = side * 0.66
        let inner = outer * 0.62
        let stroke = side * 0.075

        ZStack {
            // Ground: deep indigo → violet, warm terracotta glow bottom-right, cool glow top-left
            if layer == .all {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.11, green: 0.11, blue: 0.22), Color(red: 0.19, green: 0.13, blue: 0.34)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(RadialGradient(colors: [Palette.claude.opacity(0.55), .clear], center: UnitPoint(x: 0.85, y: 0.9), startRadius: 0, endRadius: side * 0.75))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(RadialGradient(colors: [Color.white.opacity(0.10), .clear], center: UnitPoint(x: 0.2, y: 0.1), startRadius: 0, endRadius: side * 0.6))
                )
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: size * 0.004))
                .frame(width: side, height: side)
            }

            if layer != .front {
            // Tracks
            Circle().stroke(Color.white.opacity(0.13), lineWidth: stroke).frame(width: outer, height: outer)
            Circle().stroke(Color.white.opacity(0.13), lineWidth: stroke).frame(width: inner, height: inner)

            // Outer orbit (week) — terracotta, 72 %
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(AngularGradient(colors: [Color(red: 0.93, green: 0.55, blue: 0.40), Palette.claude, Color(red: 1.0, green: 0.72, blue: 0.55)], center: .center, startAngle: .degrees(0), endAngle: .degrees(260)),
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: outer, height: outer)
                .shadow(color: Palette.claude.opacity(0.6), radius: size * 0.02)

            // Inner orbit (5h) — green, 32 %
            Circle()
                .trim(from: 0, to: 0.32)
                .stroke(Palette.ok, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: inner, height: inner)
                .shadow(color: Palette.ok.opacity(0.5), radius: size * 0.015)

            // Pace tick on the outer orbit at 45 %
            Capsule()
                .fill(Color.white.opacity(0.95))
                .frame(width: stroke * 0.22, height: stroke * 1.6)
                .offset(y: -outer / 2)
                .rotationEffect(.degrees(0.45 * 360))
            }

            if layer != .back {
            // Planet at the head of the outer orbit
            Circle()
                .fill(RadialGradient(colors: [.white, Color(red: 1.0, green: 0.85, blue: 0.75)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: stroke))
                .frame(width: stroke * 1.35, height: stroke * 1.35)
                .shadow(color: .white.opacity(0.8), radius: size * 0.02)
                .offset(y: -outer / 2)
                .rotationEffect(.degrees(0.72 * 360))

            // Claude asterisk in the centre
            Image(systemName: "asterisk")
                .font(.system(size: inner * 0.34, weight: .heavy))
                .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: size, height: size)
    }
}

extension Gallery {
    @MainActor
    static func renderIcon(to url: URL, layer: OrbitIconView.Layer = .all) {
        let renderer = ImageRenderer(content: OrbitIconView(layer: layer))
        renderer.scale = 1
        renderer.isOpaque = false
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        print("wrote \(url.path)")
    }

    /// Writes an Icon Composer bundle (macOS 26 layered icon): fill + two glass layers.
    @MainActor
    static func renderIconBundle(to dir: URL) {
        let assets = dir.appendingPathComponent("Assets")
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        renderIcon(to: assets.appendingPathComponent("Orbits.png"), layer: .back)
        renderIcon(to: assets.appendingPathComponent("Planet.png"), layer: .front)
        let json = """
        {
          "fill" : {
            "linear-gradient" : [
              "display-p3:0.11,0.11,0.22,1.00",
              "display-p3:0.22,0.14,0.36,1.00"
            ]
          },
          "groups" : [
            {
              "hidden" : false,
              "layers" : [
                {
                  "glass" : true,
                  "hidden" : false,
                  "image-name" : "Orbits.png",
                  "name" : "Orbits",
                  "position" : { "scale" : 1, "translation-in-points" : [ 0, 0 ] }
                }
              ],
              "name" : "Back",
              "shadow" : { "kind" : "neutral", "opacity" : 0.4 },
              "translucency" : { "enabled" : true, "value" : 0.5 }
            },
            {
              "hidden" : false,
              "layers" : [
                {
                  "glass" : true,
                  "hidden" : false,
                  "image-name" : "Planet.png",
                  "name" : "Planet",
                  "position" : { "scale" : 1, "translation-in-points" : [ 0, 0 ] }
                }
              ],
              "name" : "Front",
              "shadow" : { "kind" : "neutral", "opacity" : 0.6 },
              "translucency" : { "enabled" : true, "value" : 0.3 }
            }
          ],
          "supported-platforms" : {
            "circles" : [ "watchOS" ],
            "squares" : "shared"
          }
        }
        """
        try? json.write(to: dir.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
        print("wrote \(dir.path)")
    }
}
