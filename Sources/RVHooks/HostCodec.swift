import RVDomain

extension HookHost {
    /// Deny process exit: Grok `0` (JSON is the gate), Pi/OpenCode `1`.
    var denyExitCode: Int32 {
        switch self {
        case .grok, .claude:
            return 0
        case .pi, .opencode:
            return 1
        }
    }
}

public struct HookRequest: Equatable, Sendable {
    public var host: HookHost
    public var command: ShellCommand
    public var cwd: String?

    public init(host: HookHost, command: ShellCommand, cwd: String? = nil) {
        self.host = host
        self.command = command
        self.cwd = cwd
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
}
