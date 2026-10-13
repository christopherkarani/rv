import RVDomain

extension HookHost {
    /// Deny process exit: Grok/Claude/Cursor/Antigravity `0` (JSON is the gate),
    /// Pi/OpenCode/OpenClaw/Hermes `1`, Codex official honor path `2`.
    var denyExitCode: Int32 {
        switch self {
        case .grok, .claude, .cursor, .antigravity:
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
    case shell(host: HookHost, command: ShellCommand, cwd: WorkingDirectory?, session: SessionID?)
    case file(host: HookHost, file: FileToolAction, cwd: WorkingDirectory?, session: SessionID?)

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

    public var session: SessionID? {
        switch self {
        case .shell(_, _, _, let session),
             .file(_, _, _, let session):
            return session
        }
    }

    static func decoded(
        host: HookHost,
        command: String?,
        cwd: WorkingDirectory?,
        session: SessionID?,
        file: FileToolAction? = nil
    ) -> HookDecodeOutcome {
        if let file {
            return .request(.file(host: host, file: file, cwd: cwd, session: session))
        }
        guard let command, command.isEmpty == false else {
            return .malformed(.missingCommand)
        }
        return .request(.shell(
            host: host,
            command: ShellCommand(rawValue: command),
            cwd: cwd,
            session: session
        ))
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

public protocol HostCodec: Sendable {
    var host: HookHost { get }
    func decode(_ stdin: String) -> HookDecodeOutcome
    func proposedAction(from request: HookRequest) -> ProposedAction
    func encodeAllow() -> HookWire
    func encodeDeny(reason: String, rule: RuleID?, next: HookVoiceNext) -> HookWire
    func encodeEvaluatedDeny(
        from result: EvaluationResult,
        command: ShellCommand,
        unlockCode: AllowOnceUnlockMint?
    ) -> HookWire
    func encodeEvaluatedAskDeny(
        from result: EvaluationResult,
        command: ShellCommand,
        unlockCode: AllowOnceUnlockMint?,
        askRecorded: Bool
    ) -> HookWire
    func encodeFileDeny(from result: EvaluationResult) -> HookWire
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
        case .shell(_, let command, let cwd, let session):
            return .shell(
                ShellAction.effectOnly(
                    EffectShell(
                        fingerprint: ActionFingerprint.make(
                            host: host,
                            session: session,
                            cwd: cwd,
                            command: command
                        ),
                        scope: ActionScope(workingDirectory: cwd),
                        supportingCommand: command
                    )
                )
            )
        case .file(_, let file, let cwd, let session):
            return .file(
                FileAction(
                    fingerprint: ActionFingerprint.make(
                        host: host,
                        session: session,
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

    /// Grok / Pi / OpenCode / OpenClaw / Hermes / Antigravity honor JSON (`decision` key).
    /// Codex / Cursor / Claude must not call this — they own a native honor path.
    public func encodeLeftoverDecisionDeny(
        reason: String,
        rule: RuleID? = nil,
        next: HookVoiceNext = .none
    ) -> HookWire {
        HookWire(
            stdout: hookDenyJSON(
                reason: reason,
                rule: rule.map(\.slashDisplay),
                next: hookVoiceNextSentence(next)
            ),
            exitCode: host.denyExitCode
        )
    }

    /// Leftover live deny: `encodeDeny` plus `hostDenyLine` / incomplete sentence.
    public func encodeEvaluatedDeny(
        from result: EvaluationResult,
        command: ShellCommand,
        unlockCode: AllowOnceUnlockMint? = nil
    ) -> HookWire {
        switch result.decision {
        case .allow:
            return encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
        case .indeterminate:
            return encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
        case .deny(let deny):
            return encodeDeny(
                reason: hostDenyLine(command: command, reason: deny.reason, unlock: unlockCode),
                rule: deny.ruleID,
                next: unlockHookVoiceNext(unlockCode)
            )
        }
    }

    /// Ask-denial: same deny shape plus the approval-pending guidance.
    /// The policy verdict stays ASK; only the wire renders deny because no
    /// host can pause for a human. The TTY unlock line still applies, so a
    /// minted code and the RVOperatorUI row are offered together. The
    /// guidance joins AFTER `hostDenyLine`: annotating the reason would
    /// lose it to the two-sentence truncation on multi-sentence reasons.
    /// When the pending row failed to record, the guidance says so instead
    /// of promising an approval that cannot exist (M-25).
    public func encodeEvaluatedAskDeny(
        from result: EvaluationResult,
        command: ShellCommand,
        unlockCode: AllowOnceUnlockMint? = nil,
        askRecorded: Bool = true
    ) -> HookWire {
        switch result.decision {
        case .allow, .indeterminate:
            return encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
        case .deny(let deny):
            let line =
                "\(hostDenyLine(command: command, reason: deny.reason, unlock: unlockCode)) \(askPendingLine(recorded: askRecorded))"
            return encodeDeny(
                reason: line,
                rule: deny.ruleID,
                next: unlockHookVoiceNext(unlockCode)
            )
        }
    }

    /// File-tool deny. Allow stays allow; incomplete uses the PLAN sentence.
    public func encodeFileDeny(from result: EvaluationResult) -> HookWire {
        switch result.decision {
        case .allow:
            return encodeAllow()
        case .indeterminate:
            return encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
        case .deny(let deny):
            return encodeDeny(
                reason: hostFileDenyLine(reason: deny.reason),
                rule: deny.ruleID,
                next: .none
            )
        }
    }
}
