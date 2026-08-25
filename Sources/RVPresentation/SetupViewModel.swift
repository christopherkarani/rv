import RVDomain

extension HookHost {
    /// Slot label. Unpainted on the TTY show.
    public var displayName: String {
        switch self {
        case .grok: "Grok"
        case .pi: "Pi"
        case .opencode: "OpenCode"
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
    public var wrote: Set<HookHost>

    public init(
        grok: SetupSlotKind,
        pi: SetupSlotKind,
        openCode: SetupSlotKind,
        wrote: Set<HookHost>
    ) {
        self.grok = grok
        self.pi = pi
        self.openCode = openCode
        self.wrote = wrote
    }

    public func kind(for host: HookHost) -> SetupSlotKind {
        switch host {
        case .grok: grok
        case .pi: pi
        case .opencode: openCode
        }
    }

    public var occupied: [HookHost] {
        HookHost.allCases.filter { kind(for: $0) == .occupied }
    }

    public var detected: [HookHost] {
        HookHost.allCases.filter { kind(for: $0) != .pending }
    }

    public var isHostless: Bool { detected.isEmpty }

    public var hasWiredSlot: Bool {
        grok == .wired || pi == .wired || openCode == .wired
    }

    /// Second matching run: hosts already present, this run wrote nothing, none occupied.
    public var isQuiet: Bool {
        detected.isEmpty == false && wrote.isEmpty && occupied.isEmpty
    }

    /// Terminal outcome of the run. Sole owner of closer decisions for every renderer.
    public var closer: SetupCloser {
        if isQuiet { return .quiet }
        if isHostless { return .hostless }
        if hasWiredSlot { return .complete(skipped: occupied) }
        return .skipped(skipped: occupied)
    }

    public var slotViews: [SetupSlotView] {
        HookHost.allCases.map { host in
            let kind = kind(for: host)
            return SetupSlotView(host: host, kind: kind, clause: setupSlotClause(host: host, kind: kind))
        }
    }
}

/// One of the three TTY setup rows.
public struct SetupSlotView: Equatable, Sendable {
    public var host: HookHost
    public var kind: SetupSlotKind
    /// Unpainted clause (`reload /hooks`, `skipped occupied`). Nil when the row is bare.
    public var clause: String?

    public init(host: HookHost, kind: SetupSlotKind, clause: String? = nil) {
        self.host = host
        self.kind = kind
        self.clause = clause
    }
}

/// Closed taxonomy of terminal `rv setup` outcomes. One owner: ceremony closers,
/// pretty text, and `--robot` lines all switch over it exhaustively.
public enum SetupCloser: Equatable, Sendable {
    /// Second matching run wrote nothing new; nothing prints.
    case quiet
    /// No hosts detected.
    case hostless
    /// At least one host wired this run; payload lists occupied skips in host order.
    case complete(skipped: [HookHost])
    /// Every detected host was occupied; nothing wired.
    case skipped(skipped: [HookHost])

    /// Ceremony closer lines for `kind`.
    /// Quiet is empty; hostless and occupied-only both return the hostless pair;
    /// complete is `Hooks wired` (setup) or the install closer.
    public func lines(kind: SetupCeremonyKind) -> [String] {
        switch self {
        case .quiet: []
        case .hostless, .skipped: [setupCeremonyHostlessTitle, setupCeremonyHostlessNext]
        case .complete:
            switch kind {
            case .setup: [setupCeremonyHooksWired]
            case .install: [setupCeremonyInstallCloser]
            }
        }
    }
}

public let setupRobotHostlessLine = "Run rv setup after Pi, Grok, or OpenCode exists."
public let setupRobotCompleteLine = "Setup complete. Next  rv test 'git reset --hard'."

extension HookHost {
    /// `--robot` skip sentence for an occupied owned hook.
    public var robotSkipLine: String {
        switch self {
        case .grok: "Skipped occupied grok hook."
        case .pi: "Skipped occupied pi hook."
        case .opencode: "Skipped occupied opencode hook."
        }
    }
}

public let setupGrokReloadClause = "reload /hooks"
public let setupOccupiedClause = "skipped occupied"
