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
    func kind(_ host: SetupHostKind) -> SetupSlotKind {
        switch host {
        case .grok: grok
        case .pi: pi
        case .openCode: openCode
        }
    }
    let occupied = SetupHostKind.allCases.filter { kind($0) == .occupied }
    let detected = SetupHostKind.allCases.filter { kind($0) != .pending }
    if detected.isEmpty == false && wrote.isEmpty && occupied.isEmpty {
        return .quiet
    }
    let lastWired = SetupHostKind.allCases.last { wrote.contains($0) }
    let closer: SetupCloser = (grok == .wired || pi == .wired || openCode == .wired)
        ? .complete
        : .hostless
    return .painted(
        SetupViewModel(
            slots: SetupHostKind.allCases.map { host in
                SetupSlotView(host: host, kind: kind(host), clause: clause(host: host, kind: kind(host)))
            },
            activity: lastWired.map { "wiring \($0.displayName)" } ?? setupLookingActivity,
            closer: closer
        )
    )
}

private func clause(host: SetupHostKind, kind: SetupSlotKind) -> String? {
    switch kind {
    case .wired where host == .grok:
        return setupGrokReloadClause
    case .occupied:
        return setupOccupiedClause
    case .pending, .wired:
        return nil
    }
}
