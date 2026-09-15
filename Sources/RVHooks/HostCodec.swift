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

public enum HookInvocation: Equatable, Sendable {
    case shell(command: ShellCommand, ask: HostAskHookIntent?)
    case file(FileToolAction)
}

public struct HookRequest: Equatable, Sendable {
    public var host: HookHost
    public var cwd: WorkingDirectory?
    public var session: SessionID?
    public var invocation: HookInvocation

    public init(
        host: HookHost,
        cwd: WorkingDirectory? = nil,
        session: SessionID? = nil,
        invocation: HookInvocation
    ) {
        self.host = host
        self.cwd = cwd
        self.session = session
        self.invocation = invocation
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
    func encodeAsk(reason: String, rule: RuleID?, next: HookVoiceNext) -> HookWire
}

extension HostCodec {
    /// Maps a decoded `.shell` request to an empty-effect shell action.
    ///
    /// Fingerprint spelling is `ActionFingerprint.make`. File requests do not
    /// use an empty-command shell fingerprint. Command text remains supporting
    /// evidence; nil session and cwd occupy empty field slots.
    public func proposedAction(from request: HookRequest) -> ProposedAction {
        switch request.invocation {
        case .shell(let command, _):
            return .shell(
                ShellAction(
                    fingerprint: ActionFingerprint.make(
                        host: host,
                        session: request.session,
                        cwd: request.cwd,
                        command: command
                    ),
                    scope: ActionScope(workingDirectory: request.cwd),
                    supportingCommand: command
                )
            )
        case .file(let file):
            return .shell(
                ShellAction(
                    fingerprint: ActionFingerprint(
                        rawValue: "\(host.rawValue):\(request.session?.rawValue ?? ""):\(request.cwd?.rawValue ?? ""):file:\(file.kind.rawValue):\(file.path.rawValue)"
                    ),
                    scope: ActionScope(workingDirectory: request.cwd),
                    supportingCommand: nil
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
                rule: rule.map(displayRuleID),
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
                rule: rule.map(displayRuleID),
                next: hookVoiceNextSentence(next)
            ),
            exitCode: host.denyExitCode
        )
    }
}
