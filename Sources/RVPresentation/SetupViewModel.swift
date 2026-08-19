/// v1 host shown as a TTY setup slot.
public enum SetupHostKind: Equatable, Sendable, CaseIterable {
    case grok
    case pi
    case openCode

    /// Slot label. Unpainted on the TTY show.
    public var displayName: String {
        switch self {
        case .grok: "Grok"
        case .pi: "Pi"
        case .openCode: "OpenCode"
        }
    }
}

/// Outcome of one host slot after `rv setup`.
public enum SetupSlotKind: Equatable, Sendable {
    /// Host not detected, or not wired.
    case pending
    /// Owned file matches the current template.
    case wired
    /// Owned filename exists and is not the current template.
    case occupied
}

/// One of the three TTY setup rows.
public struct SetupSlotView: Equatable, Sendable {
    public var host: SetupHostKind
    public var kind: SetupSlotKind
    /// Unpainted clause (`reload /hooks`, `skipped occupied`). Nil when the row is bare.
    public var clause: String?

    public init(host: SetupHostKind, kind: SetupSlotKind, clause: String? = nil) {
        self.host = host
        self.kind = kind
        self.clause = clause
    }
}

/// TTY `rv setup` show. Circles are the only ink; words stay default terminal color.
public struct SetupViewModel: Equatable, Sendable {
    public var slots: [SetupSlotView]
    public var activity: String
    public var closerTitle: String
    public var closerNext: String
    /// Second matching run: no extra chatter.
    public var isQuiet: Bool

    public init(
        slots: [SetupSlotView],
        activity: String,
        closerTitle: String,
        closerNext: String,
        isQuiet: Bool
    ) {
        self.slots = slots
        self.activity = activity
        self.closerTitle = closerTitle
        self.closerNext = closerNext
        self.isQuiet = isQuiet
    }
}
