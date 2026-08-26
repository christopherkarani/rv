import RVDomain

extension HookHost {
    /// Deny process exit: Grok `0` (JSON is the gate), Pi/OpenCode/OpenClaw/Hermes `1`.
    var denyExitCode: Int32 {
        switch self {
        case .grok, .claude:
            return 0
        case .pi, .opencode, .openclaw, .hermes:
            return 1
        }
    }
}

/// Same-turn PolicyGate spend requested by a host Ask callback.
public enum HostAskHookIntent: String, Sendable, Equatable {
    case spend
}

public struct HookRequest: Equatable, Sendable {
    public var host: HookHost
    public var command: ShellCommand
    public var cwd: WorkingDirectory?
    public var session: String?
    public var hostAsk: HostAskHookIntent?

    public init(
        host: HookHost,
        command: ShellCommand,
        cwd: WorkingDirectory? = nil,
        session: String? = nil,
        hostAsk: HostAskHookIntent? = nil
    ) {
        self.host = host
        self.command = command
        self.cwd = cwd
        self.session = session
        self.hostAsk = hostAsk
    }
}

public struct HookWire: Equatable, Sendable {
    public var stdout: String
    public var exitCode: Int32

    public init(stdout: String, exitCode: Int32) {
        self.stdout = stdout
        self.exitCode = exitCode
    }
}

public protocol HostCodec: Sendable {
    var host: HookHost { get }
    func decode(_ stdin: String) -> HookDecodeOutcome
    func encodeAllow() -> HookWire
    func encodeDeny(reason: String, rule: String?, next: String?) -> HookWire
    func encodeAsk(reason: String, rule: String?, next: String?) -> HookWire
}

extension HostCodec {
    /// Returns empty stdout and exit 0.
    public func encodeAllow() -> HookWire {
        HookWire(stdout: "", exitCode: 0)
    }

    /// Returns deny JSON plus a trailing newline, with this host's deny exit code.
    /// `rule` and `next` are omitted from JSON when nil or empty.
    public func encodeDeny(reason: String, rule: String? = nil, next: String? = nil) -> HookWire {
        HookWire(
            stdout: hookDenyJSON(reason: reason, rule: rule, next: next),
            exitCode: host.denyExitCode
        )
    }

    /// Short Ask JSON. Not empty allow. Not a `Decision.ask` case.
    public func encodeAsk(reason: String, rule: String? = nil, next: String? = nil) -> HookWire {
        HookWire(
            stdout: hookAskJSON(reason: reason, rule: rule, next: next),
            exitCode: host.denyExitCode
        )
    }
}
