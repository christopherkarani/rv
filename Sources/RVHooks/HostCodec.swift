import RVDomain

extension HookHost {
    /// Deny process exit: Grok/Claude/Cursor `0` (JSON is the gate),
    /// Pi/OpenCode/OpenClaw/Hermes `1`, Codex official honor path `2`.
    var denyExitCode: Int32 {
        switch self {
        case .grok, .claude, .cursor:
            return 0
        case .pi, .opencode, .openclaw, .hermes:
            return 1
        case .codex:
            return 2
        }
    }
}

/// Same-turn PolicyGate spend requested by a host Ask callback.
public enum HostAskHookIntent: String, Sendable, Equatable {
    case spend
}

/// Closed payload for `HookRequest.decoded`. Shell-vs-file exclusivity is
/// structural: a file payload cannot carry command text or a spend flag.
enum HookDecodedPayload: Sendable {
    case shell(command: String?, ask: HostAskHookIntent?)
    case file(FileToolAction)
}

/// What a codec decoded from host stdin. Closed over shell, file tool, or same-turn spend.
public enum HookRequest: Equatable, Sendable {
    case shell(host: HookHost, command: ShellCommand, cwd: WorkingDirectory?, session: SessionID?)
    case file(host: HookHost, file: FileToolAction, cwd: WorkingDirectory?, session: SessionID?)
    case spend(host: HookHost, command: ShellCommand, cwd: WorkingDirectory?, session: SessionID?)

    public var host: HookHost {
        switch self {
        case .shell(let host, _, _, _),
             .file(let host, _, _, _),
             .spend(let host, _, _, _):
            return host
        }
    }

    public var cwd: WorkingDirectory? {
        switch self {
        case .shell(_, _, let cwd, _),
             .file(_, _, let cwd, _),
             .spend(_, _, let cwd, _):
            return cwd
        }
    }

    public var session: SessionID? {
        switch self {
        case .shell(_, _, _, let session),
             .file(_, _, _, let session),
             .spend(_, _, _, let session):
            return session
        }
    }

    /// Shell-vs-file exclusivity is structural: the unrepresentable
    /// combinations (file + command, file + spend flag) cannot be built.
    /// A shell payload without command text is `.malformed(.missingCommand)`;
    /// spend still requires command text.
    static func decoded(
        host: HookHost,
        cwd: WorkingDirectory?,
        session: SessionID?,
        payload: HookDecodedPayload
    ) -> HookDecodeOutcome {
        switch payload {
        case .file(let file):
            return .request(.file(host: host, file: file, cwd: cwd, session: session))
        case .shell(let command, let ask):
            guard let command, command.isEmpty == false else {
                return .malformed(.missingCommand)
            }
            let shell = ShellCommand(rawValue: command)
            if ask == .spend {
                return .request(.spend(host: host, command: shell, cwd: cwd, session: session))
            }
            return .request(.shell(host: host, command: shell, cwd: cwd, session: session))
        }
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
    func encodeFileDeny(from result: EvaluationResult) -> HookWire
}

/// Spend-first pause encoding. Hosts that cannot pause do not conform.
public protocol HostAskCodec: HostCodec {
    func encodeAsk(reason: String, rule: RuleID?, next: HookVoiceNext) -> HookWire
}

/// Production codec plus whether it can encode Ask. Spend-first hosts stay
/// `HostAskCodec` so `hookWire` does not recover Ask with a downcast.
enum ProductionHostCodec: Sendable {
    case ask(any HostAskCodec)
    case denyOnly(any HostCodec)
}

/// One switch for production codecs.
func productionHostCodec(_ host: HookHost) -> ProductionHostCodec {
    switch host {
    case .pi: .ask(PiHostCodec())
    case .opencode: .ask(OpenCodeHostCodec())
    case .claude: .ask(ClaudeHostCodec())
    case .openclaw: .ask(OpenClawHostCodec())
    case .hermes: .ask(HermesHostCodec())
    case .grok: .denyOnly(GrokHostCodec())
    case .codex: .denyOnly(CodexHostCodec())
    case .cursor: .denyOnly(CursorHostCodec())
    }
}

/// Mixed-list factory. Ask encoding uses `productionHostCodec`, not this existential.
public func makeHostCodec(_ host: HookHost) -> any HostCodec {
    switch productionHostCodec(host) {
    case .ask(let codec):
        codec
    case .denyOnly(let codec):
        codec
    }
}

extension HostCodec {
    /// Maps a decoded request to a proposed action.
    ///
    /// `.shell` / `.spend` stay empty-effect shell actions. Fingerprint
    /// spelling is `ActionFingerprint.make`. Command text remains supporting
    /// evidence; nil session and cwd occupy empty field slots.
    /// `.file` is a `FileAction` with `resources.path` set; the path never
    /// becomes `ShellCommand` / `supportingCommand`.
    public func proposedAction(from request: HookRequest) -> ProposedAction {
        switch request {
        case .shell(_, let command, let cwd, let session),
             .spend(_, let command, let cwd, let session):
            return .shell(
                ShellAction(
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
                    effects: ActionEffects(),
                    resources: ActionResources(path: file.path.rawValue),
                    scope: ActionScope(workingDirectory: cwd)
                )
            )
        }
    }

    /// Returns empty stdout and exit 0.
    public func encodeAllow() -> HookWire {
        HookWire(stdout: "", exitCode: 0)
    }

    /// Grok / Pi / OpenCode / OpenClaw / Hermes honor JSON (`decision` key).
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

    /// Short leftover Ask JSON. Not empty allow. Not a `Decision.ask` case.
    public func encodeLeftoverDecisionAsk(
        reason: String,
        rule: RuleID? = nil,
        next: HookVoiceNext = .none
    ) -> HookWire {
        HookWire(
            stdout: hookAskJSON(
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
