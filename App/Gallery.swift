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
