// Bubble's own symbols, drawn on a 24-point grid around the app's circle-and-dot logo, so the
// main features look like one family instead of stock icons.

import SwiftUI

struct BubbleGlyph: View {
    enum Kind { case record, dictate, assist }
    let kind: Kind
    /// Two-tone (theme colours) on Home cards; one colour in the sidebar.
    var tinted = true
    var lineWidth: CGFloat = 1.9

    var body: some View {
        Canvas { ctx, size in
            let u = size.width / 24
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: y * u) }
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * u, y: y * u, width: w * u, height: h * u) }
            let ink = GraphicsContext.Shading.foreground
            let line = StrokeStyle(lineWidth: lineWidth * u, lineCap: .round, lineJoin: .round)
            let accent: GraphicsContext.Shading = tinted
                ? .linearGradient(Gradient(colors: [Color(nsColor: ThemeStore.shared.current.start), Color(nsColor: ThemeStore.shared.current.end)]),
                                  startPoint: p(2, 2), endPoint: p(22, 22))
                : ink
            let soft: GraphicsContext.Shading = tinted ? .color(Theme.accent.opacity(0.9)) : ink

            switch kind {
            case .record:
                // The screen, with your camera bubble sitting on its corner and a live dot.
                ctx.stroke(Path(roundedRect: r(3, 3.5, 18, 13.5), cornerRadius: 3.5 * u), with: soft, style: line)
                let bubble = Path(ellipseIn: r(2.5, 12, 9, 9))
                ctx.blendMode = .destinationOut
                ctx.fill(Path(ellipseIn: r(1.2, 10.7, 11.6, 11.6)), with: .color(.black))  // gap around the bubble
                ctx.blendMode = .normal
                ctx.fill(bubble, with: accent)
                if tinted { ctx.fill(Path(ellipseIn: r(5.6, 15.1, 2.8, 2.8)), with: .color(.white)) }  // the logo's dot
                ctx.fill(Path(ellipseIn: r(15.4, 6.6, 3.2, 3.2)), with: accent)

            case .dictate:
                // A speech bubble that's talking: a soundwave inside.
                var b = Path(roundedRect: r(2.5, 3, 19, 14), cornerRadius: 5 * u)
                b.move(to: p(7, 17)); b.addLine(to: p(5.5, 21)); b.addLine(to: p(11, 17))
                ctx.stroke(b, with: soft, style: line)
                for (x, h) in [(7.5, 3.0), (10.5, 7.0), (13.5, 5.0), (16.5, 2.4)] {
                    var bar = Path()
                    bar.move(to: p(x, 10 - h / 2)); bar.addLine(to: p(x, 10 + h / 2))
                    ctx.stroke(bar, with: accent, style: StrokeStyle(lineWidth: 2.1 * u, lineCap: .round))
                }

            case .assist:
                // Bubble's logo with a companion orbiting it: someone who knows you, always nearby.
                ctx.stroke(Path(ellipseIn: r(3, 5, 16, 16)), with: soft, style: line)
                ctx.fill(Path(ellipseIn: r(7.6, 9.6, 6.8, 6.8)), with: accent)
                ctx.blendMode = .destinationOut
                ctx.fill(Path(ellipseIn: r(14.3, 1.3, 8.4, 8.4)), with: .color(.black))  // clears the ring under the moon
                ctx.blendMode = .normal
                ctx.fill(Path(ellipseIn: r(15.6, 2.6, 5.8, 5.8)), with: accent)
            }
        }
        .compositingGroup()
        .accessibilityHidden(true)
    }
}
