import Foundation

/// The only things Siri, Shortcuts, Spotlight and Focus may ask rv to do.
/// Every case makes rv stricter; nothing here loosens it. Thawing is an
/// owner-checked path in rv itself, so it has no case.
public enum GlanceStricterAction: String, Sendable, CaseIterable {
    /// Stop every agent rv watches mid-step. Nothing killed.
    case freeze
}

/// Who asked for the freeze, as rvd would log it.
public enum GlanceFreezeOrigin: String, Sendable, Equatable, CaseIterable {
    case intent
    case hotkey
    case focus
}

/// What one freeze request did.
public enum GlanceFreezeOutcome: Sendable, Equatable {
    case frozen(count: Int, at: Date)
    case alreadyFrozen
    /// rvd can't freeze (no verb, or not answering).
    case unavailable(String)
    case failed(String)

    /// What Siri or Shortcuts says back.
    public func dialog(calendar: Calendar) -> String {
        switch self {
        case .frozen(let count, let at):
            let agents = GlanceHeadline.plural(count, "agent")
            return "Froze \(agents) at \(GlanceClock.time(at, calendar: calendar)) · nothing killed. Thaw them in rv."
        case .alreadyFrozen:
            return "Agents are already frozen. Thaw them in rv."
        case .unavailable(let reason):
            return "rv can't freeze yet — \(reason)."
        case .failed(let reason):
            return "rv couldn't freeze agents — \(reason)."
        }
    }
}

/// Freezes every agent rv guards. There is deliberately no thaw here:
/// anything an intent can reach may only make rv stricter.
public protocol GlanceFreezeControl: Sendable {
    func freezeAll(origin: GlanceFreezeOrigin) async -> GlanceFreezeOutcome
}

/// The control until rvd exposes a freeze verb (`IPCMethod` has none).
public struct UnavailableFreezeControl: GlanceFreezeControl {
    public static let reason = "rvd doesn't expose a freeze command"

    public init() {}

    public func freezeAll(origin _: GlanceFreezeOrigin) async -> GlanceFreezeOutcome {
        .unavailable(Self.reason)
    }
}

/// The rv Focus filter's settings.
public struct GlanceFocusFilter: Sendable, Equatable {
    /// "Freeze agents when this Focus starts". Off unless the user turns it on.
    public var freezeOnStart: Bool

    public init(freezeOnStart: Bool = false) {
        self.freezeOnStart = freezeOnStart
    }
}

public enum GlanceFocusTransition: Sendable, Equatable, CaseIterable {
    case started
    case ended
}

/// Turns a Focus change into actions. A Focus may freeze on start when
/// the user asked for it; ending a Focus never thaws.
public enum GlanceFocusPlanner {
    public static func actions(
        for filter: GlanceFocusFilter, on transition: GlanceFocusTransition
    ) -> [GlanceStricterAction] {
        switch transition {
        case .started: filter.freezeOnStart ? [.freeze] : []
        case .ended: []
        }
    }
}
