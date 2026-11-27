#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import Foundation
import SwiftUI
import Testing
import RVGlance
@testable import RVGlanceUI

/// Renders the Glance popover and the menu bar glyph for each of the seven
/// states, light and dark. Each render must produce a real image; set
/// `RV_GLANCE_SNAPSHOTS=<dir>` to also write the PNGs for a visual check.
@MainActor
struct GlanceSnapshotTests {
    @Test(arguments: GlanceGlyph.allCases)
    func popoverRendersEveryState(_ glyph: GlanceGlyph) throws {
        for scheme in [ColorScheme.light, .dark] {
            let image = try render(GlancePopover(
                state: GlanceSamples.state(glyph), now: GlanceSamples.now, calendar: GlanceSamples.calendar,
                onQuit: {}), scheme: scheme)
            #expect(image.width == Int(GlanceTheme.popoverWidth * 2))
            #expect(image.height > 300)
            #expect(Self.inkedFraction(image) > 0.01)
            try write(image, name: "popover-\(glyph.rawValue)-\(scheme == .dark ? "dark" : "light")")
        }
    }

    @Test(arguments: GlanceGlyph.allCases)
    func glyphImageIsATemplateUnlessItEarnsColour(_ glyph: GlanceGlyph) throws {
        let image = GlanceGlyphImage.make(glyph)
        #expect(image.isTemplate == !glyph.isTinted)
        #expect(image.size == NSSize(width: GlanceGlyphImage.pointSize, height: GlanceGlyphImage.pointSize))
        let big = try render(GlanceGlyphView(glyph, foreground: .black).frame(width: 64, height: 64)
            .background(Color.white), scheme: .light)
        #expect(Self.inkedFraction(big, threshold: 128) > 0.05)
        try write(big, name: "glyph-\(glyph.rawValue)")
    }

    @Test func theSevenGlyphsAreSevenDifferentDrawings() throws {
        var seen: Set<Data> = []
        for glyph in GlanceGlyph.allCases where glyph != .needsYou {
            let image = try render(GlanceGlyphView(glyph, foreground: .black).frame(width: 32, height: 32)
                .background(Color.white), scheme: .light)
            seen.insert(try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])))
        }
        // needsYou is the guarding diamond in amber with a count beside it.
        #expect(seen.count == GlanceGlyph.allCases.count - 1)
    }

    @Test func theDownPopoverLeadsWithTheFix() {
        let state = GlanceSamples.state(.notRunning)
        let headline = GlanceHeadline(state, now: GlanceSamples.now, calendar: GlanceSamples.calendar)
        #expect(headline.title == "rv isn't running")
        #expect(GlanceHeadline.downFix == "rv doctor --fix")
    }

    // MARK: - Helpers

    private func render(_ view: some View, scheme: ColorScheme) throws -> CGImage {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, scheme)
            .environment(\.glanceStaticRendering, true)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96)))
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    /// Share of pixels that differ from the top-left (background) pixel.
    static func inkedFraction(_ image: CGImage, threshold: Int = 40) -> Double {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let base = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return 0 }
        var inked = 0
        var total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                total += 1
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let delta = abs(color.redComponent - base.redComponent) + abs(color.greenComponent - base.greenComponent)
                    + abs(color.blueComponent - base.blueComponent) + abs(color.alphaComponent - base.alphaComponent)
                if Int(delta * 255) > threshold { inked += 1 }
            }
        }
        return total == 0 ? 0 : Double(inked) / Double(total)
    }

    private func write(_ image: CGImage, name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["RV_GLANCE_SNAPSHOTS"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: url.appendingPathComponent("\(name).png"))
    }
}
#endif
