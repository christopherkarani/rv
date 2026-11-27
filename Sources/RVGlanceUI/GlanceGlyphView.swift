#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import RVGlance
import SwiftUI

/// The rv diamond in one of its seven states, drawn on a 16-point grid
/// (Menu bar v5, "The glyph"). Monochrome in `foreground`; the stop's ✕ is
/// cut out of the diamond so it reads on any background.
public struct GlanceGlyphView: View {
    let glyph: GlanceGlyph
    let foreground: Color

    public init(_ glyph: GlanceGlyph, foreground: Color = .primary) {
        self.glyph = glyph
        self.foreground = foreground
    }

    public var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 16, y: size.height / 16)
            GlanceGlyphPaths.draw(glyph, in: &context, color: foreground)
        }
        .accessibilityLabel(Text("rv: \(glyph.title)"))
    }
}

enum GlanceGlyphPaths {
    static let line: CGFloat = 1.4

    static var diamond: Path {
        polygon([CGPoint(x: 8, y: 1.5), CGPoint(x: 14.5, y: 8), CGPoint(x: 8, y: 14.5), CGPoint(x: 1.5, y: 8)])
    }

    static func draw(_ glyph: GlanceGlyph, in context: inout GraphicsContext, color: Color) {
        let shading = GraphicsContext.Shading.color(color)
        let outline = StrokeStyle(lineWidth: line, lineJoin: .round)
        switch glyph {
        case .guarding, .needsYou:
            context.fill(diamond, with: shading)
        case .watching:
            context.stroke(diamond, with: shading, style: outline)
            let left = polygon([CGPoint(x: 8, y: 1.5), CGPoint(x: 1.5, y: 8), CGPoint(x: 8, y: 14.5)])
            context.fill(left, with: shading)
        case .justStopped:
            context.drawLayer { layer in
                layer.fill(diamond, with: shading)
                var cross = Path()
                cross.move(to: CGPoint(x: 5.8, y: 5.8))
                cross.addLine(to: CGPoint(x: 10.2, y: 10.2))
                cross.move(to: CGPoint(x: 10.2, y: 5.8))
                cross.addLine(to: CGPoint(x: 5.8, y: 10.2))
                layer.blendMode = .destinationOut
                layer.stroke(cross, with: .color(.black), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        case .boxed:
            let box = Path(roundedRect: CGRect(x: 1, y: 1, width: 14, height: 14), cornerRadius: 3.5)
            context.stroke(box, with: shading, lineWidth: 1.2)
            let inner = polygon([
                CGPoint(x: 8, y: 4), CGPoint(x: 12, y: 8), CGPoint(x: 8, y: 12), CGPoint(x: 4, y: 8),
            ])
            context.fill(inner, with: shading)
        case .paused:
            context.stroke(diamond, with: shading, style: outline)
        case .notRunning:
            context.stroke(diamond, with: .color(color.opacity(0.55)), style: outline)
            var slash = Path()
            slash.move(to: CGPoint(x: 2.5, y: 13.5))
            slash.addLine(to: CGPoint(x: 13.5, y: 2.5))
            context.stroke(slash, with: shading, style: StrokeStyle(lineWidth: line, lineCap: .round))
        }
    }

    static func polygon(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

/// The menu bar image. A template (the system tints it like every other
/// status item) unless the state earns colour: amber for a question, red
/// for a stop.
public enum GlanceGlyphImage {
    public static let pointSize: CGFloat = 15

    @MainActor
    public static func make(_ glyph: GlanceGlyph, pointSize: CGFloat = pointSize, scale: CGFloat = 2) -> NSImage {
        let tint: Color = switch glyph {
        case .needsYou: GlanceTheme.watch
        case .justStopped: GlanceTheme.stop
        default: .black
        }
        let renderer = ImageRenderer(content: GlanceGlyphView(glyph, foreground: tint)
            .frame(width: pointSize, height: pointSize))
        renderer.scale = scale
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.size = NSSize(width: pointSize, height: pointSize)
        image.isTemplate = !glyph.isTinted
        image.accessibilityDescription = "rv: \(glyph.title)"
        return image
    }
}
#endif
