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

/// Pretty closer after the three slots. `.complete` only when a slot is wired.
public enum SetupCloser: Equatable, Sendable {
    case complete
    case hostless

    /// Ceremony closer copy. Install substitutes the install-only line; setup stays `Hooks wired`.
    public func lines(kind: SetupCeremonyKind) -> [String] {
        switch self {
        case .hostless:
            [setupCeremonyHostlessTitle, setupCeremonyHostlessNext]
        case .complete:
            switch kind {
            case .setup: [setupCeremonyHooksWired]
            case .install: [setupCeremonyInstallCloser]
            }
        }
    }
}

public let setupGrokReloadClause = "reload /hooks"
public let setupOccupiedClause = "skipped occupied"
