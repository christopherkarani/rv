import Foundation
import RVDomain

/// The popover's first line and the one under it, as words.
public struct GlanceHeadline: Sendable, Equatable {
    public var title: String
    public var subtitle: String

    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    public init(_ state: GlanceState, now: Date, calendar: Calendar) {
        let glyph = state.glyph(at: now)
        let rvd = Self.rvdWords(state.link)
        switch glyph {
        case .notRunning:
            if state.link == .connecting {
                self.init(title: "Connecting to rvd", subtitle: "nothing is confirmed yet")
            } else {
                self.init(title: "rv isn't running", subtitle: "rvd isn't answering · agents are unguarded")
            }
        case .needsYou:
            let count = state.pending.count
            self.init(title: glyph.title, subtitle: "\(Self.plural(count, "ask")) waiting · \(rvd)")
        case .justStopped:
            let host = state.lastStop.map { GlanceAgent.displayName($0.host) } ?? "an agent"
            self.init(title: glyph.title, subtitle: "\(host) · \(rvd)")
        case .watching:
            self.init(title: glyph.title, subtitle: "\(Self.watchWords(state.posture)) · \(rvd)")
        case .boxed:
            self.init(title: glyph.title, subtitle: "\(Self.plural(state.boxesRunning, "box")) running · \(rvd)")
        case .paused:
            let back = state.pausedUntil.map { GlanceClock.time($0, calendar: calendar) } ?? "later"
            self.init(title: glyph.title, subtitle: "back at \(back) · \(rvd)")
        case .guarding:
            let agents = state.activeAgentCount(at: now)
            self.init(title: glyph.title, subtitle: "\(Self.plural(agents, "agent")) · \(rvd)")
        }
    }

    /// The command to type when rvd is down.
    public static let downFix = "\(CommandVocabulary.Command.doctor.invocation) --fix"

    static func rvdWords(_ link: GlanceLink) -> String {
        switch link {
        case .liveWithoutEvents: "rvd is older than live events"
        default: "rvd healthy"
        }
    }

    static func watchWords(_ posture: GlancePosture) -> String {
        guard case .watching(let hosts) = posture, !hosts.isEmpty else { return "every agent in watch mode" }
        let names = hosts.map(GlanceAgent.displayName).joined(separator: ", ")
        return "\(names) in watch mode"
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        let suffix = noun.hasSuffix("x") ? "es" : "s"
        return count == 1 ? "1 \(noun)" : "\(count) \(noun)\(suffix)"
    }
}
