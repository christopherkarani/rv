import RVDomain

extension HookHost {
    /// Deny process exit: Grok/Claude/Cursor/Antigravity/Muse `0` (JSON is the gate),
    /// Pi/OpenCode/OpenClaw/Hermes `1`, Codex official honor path `2`.
    var denyExitCode: Int32 {
        switch self {
        case .grok, .claude, .cursor, .antigravity, .muse:
            return 0
        case .pi, .opencode, .openclaw, .hermes:
            return 1
        case .codex:
            return 2
        }
    }
}

/// What a codec decoded from host stdin. Closed over shell and file tool.
///
/// Step 8B: the host "spend" attestation ("our native Ask UI already
/// approved") is removed. It was a bare caller-controlled string with no
/// authentication, no human proof, and no continuation binding — it could
/// not satisfy "real human authorization or fail closed". Hosts that still
/// send it decode as ordinary shell requests; the attestation is ignored.
public enum HookRequest: Equatable, Sendable {
    case shell(host: HookHost, command: ShellCommand, cwd: WorkingDirectory?, sessions: HookSessionIDs)
    case file(host: HookHost, file: FileToolAction, cwd: WorkingDirectory?, sessions: HookSessionIDs)

    /// A request whose one session id serves both roles.
    public static func shell(
        host: HookHost, command: ShellCommand, cwd: WorkingDirectory?, session: SessionID?
    ) -> HookRequest {
        .shell(host: host, command: command, cwd: cwd, sessions: HookSessionIDs(attribution: session))
    }

    /// A request whose one session id serves both roles.
    public static func file(
        host: HookHost, file: FileToolAction, cwd: WorkingDirectory?, session: SessionID?
    ) -> HookRequest {
        .file(host: host, file: file, cwd: cwd, sessions: HookSessionIDs(attribution: session))
    }

    public var sessions: HookSessionIDs {
        switch self {
        case .shell(_, _, _, let sessions),
             .file(_, _, _, let sessions):
            return sessions
        }
    }

    /// The host session id: block rows, audit detail. Nil when the host
    /// sent none.
    public var session: SessionID? { sessions.attribution }

    /// What a pending approval is keyed by (`HookSessionIDs.approval`).
    public var approvalSession: SessionID? { sessions.approval }

    public var host: HookHost {
        switch self {
        case .shell(let host, _, _, _),
             .file(let host, _, _, _):
            return host
        }
    }

    public var cwd: WorkingDirectory? {
        switch self {
        case .shell(_, _, let cwd, _),
             .file(_, _, let cwd, _):
            return cwd
        }
    }

    /// `approvalSession`: a narrower host id (a Codex or Muse turn, a
    /// Hermes task) that may key a pending approval when the host sent no
    /// session id; never an attribution. Defaults to `session`.
    static func decoded(
        host: HookHost,
        command: String?,
        cwd: WorkingDirectory?,
        session: SessionID?,
        approvalSession: SessionID? = nil,
        file: FileToolAction? = nil
    ) -> HookDecodeOutcome {
        let sessions = HookSessionIDs(attribution: session, approval: approvalSession)
        if let file {
            return .request(.file(host: host, file: file, cwd: cwd, sessions: sessions))
        }
        guard let command, command.isEmpty == false else {
            return .malformed(.missingCommand)
        }
        return .request(.shell(
            host: host,
            command: ShellCommand(rawValue: command),
            cwd: cwd,
            sessions: sessions
        ))
    }
}

/// The two jobs a host's ids do. `attribution` is the host's session id
/// only: it names the agent session on block and audit rows. `approval`
/// keys a pending approval and its action fingerprint, and falls back to a
/// narrower id (turn, task) when there is no session id, so an ask can
/// still wait for a human; it is `attribution` whenever that is set.
public struct HookSessionIDs: Equatable, Sendable {
    public var attribution: SessionID?
    public var approval: SessionID?

    public init(attribution: SessionID?, approval: SessionID? = nil) {
        self.attribution = attribution
        self.approval = attribution ?? approval
    }
}

/// Deny presentation: the composed deny content before per-adapter wire
/// rendering. `HookMapper` (the deny-dispatch module) composes it once at
/// this seam; adapters only render. `reason` is the stop text, already
/// composed (`StopNotice.text`: one shape for every stop). `matched`
/// carries the deny's rule match across the seam as data so the Claude
/// adapter can render its rich shape; adapters without a rich shape ignore
/// it. `nextText` is the stop's `who` line, for hosts whose JSON carries a
/// separate `next`. `agentText` is the agent-facing text (Cursor
/// `agent_message`): the same stop text unless a caller says otherwise, so
/// the agent reads what the person reads.
public struct HookDenyPresentation: Equatable, Sendable {
    public var reason: String
    public var rule: RuleID?
    public var next: HookVoiceNext
    public var matched: RuleMatch?
    public var nextText: String?
    public var agentText: String

    public init(
        reason: String,
        rule: RuleID? = nil,
        next: HookVoiceNext = .none,
        matched: RuleMatch? = nil,
        nextText: String? = nil,
        agentText: String? = nil
    ) {
        self.reason = reason
        self.rule = rule
        self.next = next
        self.matched = matched
        self.nextText = nextText ?? hookVoiceNextSentence(next)
        self.agentText = agentText ?? reason
    }
}

public struct HookWire: Equatable, Sendable {
    public var stdout: String
    public var exitCode: Int32
    /// Codex honor path: exit 2 without a stderr blocking reason fail-opens the tool.
    public var stderr: String

    public init(stdout: String, exitCode: Int32, stderr: String = "") {
        self.stdout = stdout
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

/// Host adapter interface: decode host stdin and render allow/deny wire.
/// One deny rendering entry — `encodeDeny(_:)` — takes the presentation
/// `HookMapper` composed; the evaluated/ask/file dispatch that produced
/// it lives in `HookMapper`, not per adapter.
public protocol HostCodec: Sendable {
    var host: HookHost { get }
    func decode(_ stdin: String) -> HookDecodeOutcome
    func proposedAction(from request: HookRequest) -> ProposedAction
    func encodeAllow() -> HookWire
    func encodeDeny(_ presentation: HookDenyPresentation) -> HookWire
    /// Session-start reply carrying rv's house rules (B4). Hosts with no
    /// session-start context wire keep the default, an allow.
    func encodeHouseRules(_ text: String) -> HookWire
}

/// One switch for production codecs. Step 8B: every host is deny/allow
/// on the wire; human approval arrives via RVOperatorUI or TTY allow-once
/// plus agent retry, never via host-native spend.
public func productionHostCodec(_ host: HookHost) -> any HostCodec {
    switch host {
    case .pi: PiHostCodec()
    case .opencode: OpenCodeHostCodec()
    case .claude: ClaudeHostCodec()
    case .openclaw: OpenClawHostCodec()
    case .hermes: HermesHostCodec()
    case .grok: GrokHostCodec()
    case .codex: CodexHostCodec()
    case .cursor: CursorHostCodec()
    case .antigravity: AntigravityHostCodec()
    case .muse: MuseHostCodec()
    }
}

extension HostCodec {
    /// Maps a decoded request to a proposed action.
    ///
    /// `.shell` stays an empty-effect shell action. Fingerprint
    /// spelling is `ActionFingerprint.make`. Command text remains supporting
    /// evidence; nil session and cwd occupy empty field slots.
    /// `.file` is a `FileAction` with `resources.path` set; the path never
    /// becomes `ShellCommand` / `supportingCommand`.
    public func proposedAction(from request: HookRequest) -> ProposedAction {
        switch request {
        case .shell(_, let command, let cwd, let sessions):
            return .shell(
                ShellAction.effectOnly(
                    EffectShell(
                        fingerprint: ActionFingerprint.make(
                            host: host,
                            session: sessions.attribution,
                            cwd: cwd,
                            command: command
                        ),
                        scope: ActionScope(workingDirectory: cwd),
                        supportingCommand: command
                    )
                )
            )
        case .file(_, let file, let cwd, let sessions):
            return .file(
                FileAction(
                    fingerprint: ActionFingerprint.make(
                        host: host,
                        session: sessions.attribution,
                        cwd: cwd,
                        file: file
                    ),
                    file: file,
                    scope: ActionScope(workingDirectory: cwd)
                )
            )
        }
    }

    /// Returns empty stdout and exit 0.
    public func encodeAllow() -> HookWire {
        HookWire(stdout: "", exitCode: 0)
    }

    /// No session-start context wire: the event passes like a foreign one.
    public func encodeHouseRules(_ text: String) -> HookWire {
        encodeAllow()
    }

    /// Grok / Pi / OpenCode / OpenClaw / Hermes / Antigravity honor JSON (`decision` key).
    /// Codex / Cursor / Claude must not call this — they own a native honor path.
    public func encodeLeftoverDecisionDeny(_ presentation: HookDenyPresentation) -> HookWire {
        HookWire(
            stdout: hookDenyJSON(
                reason: presentation.reason,
                rule: presentation.rule.map(\.slashDisplay),
                next: presentation.nextText
            ),
            exitCode: host.denyExitCode
        )
    }

    /// `encodeLeftoverDecisionDeny(_:)` from parts.
    public func encodeLeftoverDecisionDeny(
        reason: String,
        rule: RuleID? = nil,
        next: HookVoiceNext = .none
    ) -> HookWire {
        encodeLeftoverDecisionDeny(HookDenyPresentation(reason: reason, rule: rule, next: next))
    }

    /// Plain presentation from parts: no matched rule, agent stop line.
    /// The spelling plain-sentence callers (malformed payload, daemon
    /// unreachable, timeout) use; rendering still crosses the single
    /// `encodeDeny(_:)` entry.
    public func encodeDeny(
        reason: String,
        rule: RuleID? = nil,
        next: HookVoiceNext = .none
    ) -> HookWire {
        encodeDeny(HookDenyPresentation(reason: reason, rule: rule, next: next))
    }
}
