import RVDomain

public enum HookHost: String, Equatable, Sendable {
    case grok
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
