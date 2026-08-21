/// v1 host shown as a TTY setup slot.
public enum SetupHostKind: Equatable, Hashable, Sendable, CaseIterable {
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

/// Closed snapshot of the three setup slots plus which hosts this run wrote.
public struct SetupSlotSnapshot: Equatable, Sendable {
    public var grok: SetupSlotKind
    public var pi: SetupSlotKind
    public var openCode: SetupSlotKind
    public var wrote: Set<SetupHostKind>

    public init(
        grok: SetupSlotKind,
        pi: SetupSlotKind,
        openCode: SetupSlotKind,
        wrote: Set<SetupHostKind>
    ) {
        self.grok = grok
        self.pi = pi
        self.openCode = openCode
        self.wrote = wrote
    }

    public func kind(for host: SetupHostKind) -> SetupSlotKind {
        switch host {
        case .grok: grok
        case .pi: pi
        case .openCode: openCode
        }
    }

    public var occupied: [SetupHostKind] {
        SetupHostKind.allCases.filter { kind(for: $0) == .occupied }
    }

    public var detected: [SetupHostKind] {
        SetupHostKind.allCases.filter { kind(for: $0) != .pending }
    }

    public var isHostless: Bool { detected.isEmpty }

    public var hasWiredSlot: Bool {
        grok == .wired || pi == .wired || openCode == .wired
    }

    /// Second matching run: hosts already present, this run wrote nothing, none occupied.
    public var isQuiet: Bool {
        detected.isEmpty == false && wrote.isEmpty && occupied.isEmpty
    }

    public var closer: SetupCloser {
        hasWiredSlot ? .complete : .hostless
    }

    public var slotViews: [SetupSlotView] {
        SetupHostKind.allCases.map { host in
            let kind = kind(for: host)
            return SetupSlotView(host: host, kind: kind, clause: setupSlotClause(host: host, kind: kind))
        }
    }
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

/// Pretty closer after the three slots.
public enum SetupCloser: Equatable, Sendable {
    case complete
    case hostless

    public var title: String {
        switch self {
        case .complete: "Setup complete"
        case .hostless: "No hosts yet"
        }
    }

    public var next: String {
        switch self {
        case .complete: "Next  rv test 'git reset --hard'"
        case .hostless: "Next  rv setup"
        }
    }
}

/// TTY `rv setup` show. Circles are the only ink; words stay default terminal color.
public struct SetupViewModel: Equatable, Sendable {
    public var slots: [SetupSlotView]
    public var activity: String
    public var closer: SetupCloser

    public init(slots: [SetupSlotView], activity: String, closer: SetupCloser) {
        self.slots = slots
        self.activity = activity
        self.closer = closer
    }
}

/// Quiet second run, or a painted three-slot show.
public enum SetupShow: Equatable, Sendable {
    case quiet
    case painted(SetupViewModel)
}

public let setupLookingActivity = "looking for hosts"
public let setupGrokReloadClause = "reload /hooks"
public let setupOccupiedClause = "skipped occupied"

/// Builds the TTY show from slot kinds plus which hosts this run wrote.
public func setupViewModel(
    grok: SetupSlotKind,
    pi: SetupSlotKind,
    openCode: SetupSlotKind,
    wrote: Set<SetupHostKind>
) -> SetupShow {
    setupViewModel(
        SetupSlotSnapshot(grok: grok, pi: pi, openCode: openCode, wrote: wrote)
    )
}

public func setupViewModel(_ slots: SetupSlotSnapshot) -> SetupShow {
    if slots.isQuiet {
        return .quiet
    }
    let lastWired = SetupHostKind.allCases.last { slots.wrote.contains($0) }
    return .painted(
        SetupViewModel(
            slots: slots.slotViews,
            activity: lastWired.map { "wiring \($0.displayName)" } ?? setupLookingActivity,
            closer: slots.closer
        )
    )
}
