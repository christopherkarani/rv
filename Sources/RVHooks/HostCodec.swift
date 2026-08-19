import RVDomain

public enum HookHost: String, Equatable, Sendable {
    case grok
    /// Pi adapter wire, not a host protocol.
    case pi
    /// OpenCode adapter wire, not a host protocol.
    case opencode

    /// Deny process exit: Grok `0` (JSON is the gate), Pi/OpenCode `1`.
    var denyExitCode: Int32 {
        switch self {
        case .grok:
            return 0
        case .pi, .opencode:
            return 1
        }
    }
}

public struct HookRequest: Equatable, Sendable {
    public var host: HookHost
    public var command: ShellCommand?

    public init(host: HookHost, command: ShellCommand?) {
        self.host = host
        self.command = command
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
    func decode(_ stdin: String) -> HookRequest
    func encodeAllow() -> HookWire
    func encodeDeny(reason: String) -> HookWire
}

extension HostCodec {
    /// Returns empty stdout and exit 0.
    public func encodeAllow() -> HookWire {
        HookWire(stdout: "", exitCode: 0)
    }

    /// Returns deny JSON plus a trailing newline, with this host's deny exit code.
    public func encodeDeny(reason: String) -> HookWire {
        HookWire(stdout: hookDenyJSON(reason: reason), exitCode: host.denyExitCode)
    }
}
