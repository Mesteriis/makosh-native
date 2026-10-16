// Derived from Aether Courier, copyright (c) 2026 Aether Courier contributors, MIT.
// See Dependencies/Mail/Aether-Courier.MIT.notice and docs/reference-interface.md.
import SwiftUI

/// Modern "aurora glass" backdrop: a deep indigo base washed with soft, blurred
/// gradient blooms (violet, magenta, electric blue) that read as coloured light
/// behind the app's frosted-glass panels — an iOS-Liquid-Glass feel that's fancy,
/// human, and premium. `intensity` scales how vivid the blooms are per pane so
/// busier surfaces stay legible.
struct WorkspaceBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var intensity: Double = 1.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let s = max(w, h)
            ZStack {
                base
                bloom(Palette.violet,  at: CGPoint(x: w * 0.12, y: h * -0.02), r: s * 0.62)
                bloom(Palette.magenta, at: CGPoint(x: w * 1.02, y: h * 0.18),  r: s * 0.55)
                bloom(Palette.blue,    at: CGPoint(x: w * 0.55, y: h * 1.06),  r: s * 0.7)
                bloom(Palette.indigo,  at: CGPoint(x: w * -0.08, y: h * 0.82), r: s * 0.5)
                grain.opacity(0.5 * intensity)
                vignette
            }
            .compositingGroup()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var base: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.058, green: 0.050, blue: 0.104), Color(red: 0.030, green: 0.026, blue: 0.060)]
                : [Color(red: 0.960, green: 0.962, blue: 0.992), Color(red: 0.906, green: 0.918, blue: 0.980)],
            startPoint: .top, endPoint: .bottom)
    }

    private func bloom(_ color: Color, at p: CGPoint, r: CGFloat) -> some View {
        RadialGradient(
            colors: [color.opacity((scheme == .dark ? 0.42 : 0.26) * intensity), .clear],
            center: .center, startRadius: 0, endRadius: r)
        .frame(width: r * 2, height: r * 2)
        .position(p)
        .blur(radius: 34)
    }

    /// Faint film grain so the smooth gradients don't band on wide displays.
    private var grain: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func rnd() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat((seed >> 33) & 0xFFFF) / 65535.0
            }
            let dots = min(3800, Int((size.width * size.height) / 300))
            let tint = scheme == .dark ? Color.white : Color.black
            for _ in 0..<dots {
                let d = 0.6 + rnd() * 0.8
                let a = (scheme == .dark ? 0.018 : 0.02) + rnd() * 0.03
                ctx.fill(Path(ellipseIn: CGRect(x: rnd() * size.width, y: rnd() * size.height, width: d, height: d)),
                         with: .color(tint.opacity(a)))
            }
        }
    }

    private var vignette: some View {
        RadialGradient(
            colors: [.clear, Color.black.opacity(scheme == .dark ? 0.34 : 0.07)],
            center: .center, startRadius: 220, endRadius: 940)
    }

    enum Palette {
        static let violet  = Color(red: 0.49, green: 0.24, blue: 0.93)
        static let magenta = Color(red: 0.92, green: 0.28, blue: 0.60)
        static let blue    = Color(red: 0.24, green: 0.44, blue: 0.96)
        static let indigo  = Color(red: 0.36, green: 0.31, blue: 0.86)
    }
}

