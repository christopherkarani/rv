import RVDomain

/// The menu bar diamond's seven states (Menu bar v5, "The glyph"), plus
/// `connecting`, a neutral look for the moment before rvd's first reply.
/// The icon is a monochrome template image; only `needsYou` and
/// `justStopped` earn colour, and only `needsYou` breathes.
public enum GlanceGlyph: String, CaseIterable, Sendable {
    /// rv will stop destructive commands (every host in block mode).
    case guarding
    /// At least one host is in observe mode: rv logs what it would stop.
    case watching
    /// An agent is waiting on a question (a pending ask).
    case needsYou
    /// For `GlanceState.stopFlash` after a stop landed.
    case justStopped
    /// An agent works in an isolated box.
    case boxed
    /// The owner paused rv for a while.
    case paused
    /// rvd stopped answering.
    case notRunning
    /// No reply from rvd yet: neither guarding nor down is confirmed.
    case connecting

    /// The state name, shared with rv term.
    public var title: String {
        switch self {
        case .guarding: "Guarding"
        case .watching: "Watching"
        case .needsYou: "Needs you"
        case .justStopped: "Just stopped"
        case .boxed: "Boxed"
        case .paused: "Paused"
        case .notRunning: "Not running"
        case .connecting: "Connecting"
        }
    }

    /// One line on what the state means.
    public var meaning: String {
        switch self {
        case .guarding: "rv will stop destructive commands"
        case .watching: "rv logs what it \(CommandVocabulary.Glyph.watched.eventWord ?? "would stop")"
        case .needsYou: "an agent is waiting on a question"
        case .justStopped: "rv just stopped a command"
        case .boxed: "a box is running"
        case .paused: "you paused rv for a while"
        case .notRunning: "rvd is down or hooks are broken"
        case .connecting: "waiting for rvd's first reply"
        }
    }

    /// Colour in the menu bar: everything else stays a template image.
    public var isTinted: Bool {
        self == .needsYou || self == .justStopped
    }

    /// Only a question waiting for you pulses.
    public var breathes: Bool {
        self == .needsYou
    }
}
