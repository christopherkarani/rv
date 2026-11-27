#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import RVDomain
import RVGlance
import SwiftUI

/// The Glance popover (Menu bar v5 "Glance", v5b glass): is rv on, what
/// are my agents doing, did anything get stopped. Read-only: there is no
/// control here that answers an ask or loosens a rule.
public struct GlancePopover: View {
    let state: GlanceState
    let now: Date
    let calendar: Calendar
    /// The last stop's plain-English line; nil shows the template line.
    let plain: String?
    let onQuit: (() -> Void)?

    public init(
        state: GlanceState, now: Date, calendar: Calendar = .current, plain: String? = nil,
        onQuit: (() -> Void)? = nil
    ) {
        self.state = state
        self.now = now
        self.calendar = calendar
        self.plain = plain
        self.onQuit = onQuit
    }

    private var glyph: GlanceGlyph { state.glyph(at: now) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlanceHeader(glyph: glyph, headline: GlanceHeadline(state, now: now, calendar: calendar))
            if glyph == .connecting {
                // Nothing is confirmed yet: no numbers, no agents, no stop.
                Text("Waiting for rvd's first reply.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else if case .down(let reason) = state.link {
                GlanceFixRow(reason: reason)
                GlanceSeparator()
            } else {
                GlanceStats(today: state.today)
            }
            if glyph != .connecting {
                GlanceSectionTitle("Now")
                GlanceAgentRows(agents: state.recentAgents, now: now, unguarded: glyph == .notRunning)
                if let stop = state.lastStop {
                    GlanceSeparator()
                    GlanceSectionTitle("Last stop")
                    GlanceStopRow(stop: stop, plain: plain, now: now, calendar: calendar)
                }
                if state.missed > 0 {
                    Text("rv dropped \(state.missed) events while this menu was behind.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                }
            }
            GlanceFooter(onQuit: onQuit)
        }
        .padding(12)
        .frame(width: GlanceTheme.popoverWidth)
    }
}

struct GlanceHeader: View {
    let glyph: GlanceGlyph
    let headline: GlanceHeadline

    var body: some View {
        HStack(spacing: 10) {
            GlanceGlyphView(glyph, foreground: Color(hex: 0x140F33))
                .frame(width: 14, height: 14)
                .frame(width: 30, height: 30)
                .background(logoFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .modifier(Breathing(active: glyph.breathes))
            VStack(alignment: .leading, spacing: 1) {
                Text(headline.title).font(.system(size: 14, weight: .semibold))
                Text(headline.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    private var logoFill: LinearGradient {
        let colors: [Color] = switch glyph {
        case .notRunning, .justStopped: [Color(hex: 0xFFB4B4), Color(hex: 0xFF6B6B)]
        case .needsYou, .watching: [Color(hex: 0xFFE2A8), Color(hex: 0xFFB23F)]
        case .connecting: [Color(hex: 0xE4E4EA), Color(hex: 0xA9A9B4)]
        default: [Color(hex: 0xD3C9FF), Color(hex: 0x7D6BFF)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Only a question pulses; reduce-motion keeps it still.
struct Breathing: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.phaseAnimator([1.0, 0.55]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 1.2) }
        } else {
            content
        }
    }
}

struct GlanceStats: View {
    let today: GlanceToday

    var body: some View {
        HStack(spacing: 6) {
            GlanceStatTile(value: today.checked, label: "commands checked", color: .primary)
            GlanceStatTile(value: today.stopped, label: CommandVocabulary.Glyph.stopped.word.lowercased(),
                           color: GlanceTheme.stop)
            GlanceStatTile(value: today.asked, label: "asked you", color: GlanceTheme.watch)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }
}

struct GlanceStatTile: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value, format: .number)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .glanceTile(cornerRadius: 11)
        .accessibilityElement(children: .combine)
    }
}

struct GlanceFixRow: View {
    let reason: String

    var body: some View {
        HStack(spacing: 10) {
            Text("!")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(GlanceTheme.stop)
                .frame(width: 28, height: 28)
                .background(GlanceTheme.stop.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(reason).font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    Text(CommandVocabulary.Glyph.next.rawValue).foregroundStyle(GlanceTheme.rv)
                    Text(GlanceHeadline.downFix).textSelection(.enabled)
                }
                .font(.system(size: 11.5, design: .monospaced))
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(GlanceTheme.stop.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(GlanceTheme.stop.opacity(0.25)))
    }
}

struct GlanceSectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

struct GlanceSeparator: View {
    var body: some View {
        Divider().padding(.horizontal, 6).padding(.vertical, 8)
    }
}

extension EnvironmentValues {
    /// True when rendering off screen (`ImageRenderer` snapshots), where
    /// Liquid Glass draws nothing: tiles fall back to a plain fill.
    @Entry public var glanceStaticRendering = false
}

extension View {
    func glanceTile(cornerRadius: CGFloat) -> some View {
        modifier(GlanceTile(cornerRadius: cornerRadius))
    }
}

/// Liquid Glass on macOS 26, a quiet fill before it or off screen.
struct GlanceTile: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.glanceStaticRendering) private var isStatic

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // `glassEffect` exists only in the macOS 26 SDK (Swift 6.2+);
        // Xcode 16 on macOS 15 builds the plain tile.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !isStatic {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.quaternary.opacity(0.6), in: shape)
        }
        #else
        content.background(.quaternary.opacity(0.6), in: shape)
        #endif
    }
}
#endif
