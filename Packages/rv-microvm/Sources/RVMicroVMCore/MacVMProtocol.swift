import Foundation

/// Constants shared by `rv-macvm` (host) and `rv-macvm-agent` (guest).
public enum MacVMAgent {
    /// Guest vsock port the agent listens on for exec sessions.
    public static let controlPort: UInt32 = 1024
    /// How long the agent waits at boot for the guest's sshd, which starts
    /// every command, before listening anyway. Well inside the host's
    /// `MacVMRun.agentTimeoutSeconds`.
    public static let sshdReadySeconds = 60
    public static let protocolVersion = 1
    /// virtiofs tag of the workspace share; the agent mounts it at the
    /// workspace's host path.
    public static let workspaceTag = "rvws"
    /// virtiofs tag of the read-only setup share used only by `prepare`.
    public static let setupTag = "rvsetup"
    /// The account `prepare` provisions; guest commands run as it.
    public static let user = "rv"
    public static let executableName = "rv-macvm-agent"
    public static let installedPath = "/usr/local/libexec/rv-macvm-agent"
    public static let launchDaemonLabel = "dev.rv.macvm-agent"
    public static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
}

public enum MacVMProtocolError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownKind(UInt8)
    case oversized(Int)
    case malformed(String)

    public var description: String {
        switch self {
        case .unknownKind(let kind): "unknown agent frame kind \(kind)"
        case .oversized(let count): "agent frame of \(count) bytes exceeds \(MacVMFrame.maxPayloadBytes)"
        case .malformed(let kind): "malformed \(kind) frame"
        }
    }
}

/// One message on an agent connection: `[kind u8][length u32 BE][payload]`.
///
/// Host to agent: `exec` (first frame), then `input`, `resize`, `signal`.
/// Agent to host: `started` or `failure`, then `output`/`errorOutput`,
/// then exactly one `exit`.
public enum MacVMFrame: Sendable, Equatable {
    case exec(MacVMExecRequest)
    /// Guest stdin bytes; empty means end of input.
    case input(Data)
    case resize(rows: UInt16, columns: UInt16)
    case signal(Int32)
    case started
    /// The terminal, or stdout without one.
    case output(Data)
    /// stderr without a terminal.
    case errorOutput(Data)
    /// Shell convention: the exit code, or 128 + signal.
    case exit(Int32)
    case failure(String)

    /// Bounds the exec request (environment included) and output chunks.
    public static let maxPayloadBytes = 1 << 20

    public enum Kind: UInt8, Sendable {
        case exec = 1, input = 2, resize = 3, signal = 4
        case started = 16, output = 17, errorOutput = 18, exit = 19, failure = 20
    }

    public func encoded() -> Data {
        let (kind, payload): (Kind, Data) = switch self {
        case .exec(let request): (.exec, (try? JSONEncoder().encode(request)) ?? Data())
        case .input(let data): (.input, data)
        case .resize(let rows, let columns): (.resize, Self.bigEndian(rows) + Self.bigEndian(columns))
        case .signal(let number): (.signal, Self.bigEndian(number))
        case .started: (.started, Data())
        case .output(let data): (.output, data)
        case .errorOutput(let data): (.errorOutput, data)
        case .exit(let status): (.exit, Self.bigEndian(status))
        case .failure(let message): (.failure, Data(message.utf8))
        }
        var frame = Data([kind.rawValue])
        frame.append(Self.bigEndian(UInt32(payload.count)))
        frame.append(payload)
        return frame
    }

    static func decode(kind raw: UInt8, payload: Data) throws(MacVMProtocolError) -> MacVMFrame {
        guard let kind = Kind(rawValue: raw) else { throw .unknownKind(raw) }
        switch kind {
        case .exec:
            guard let request = try? JSONDecoder().decode(MacVMExecRequest.self, from: payload) else {
                throw .malformed("exec")
            }
            return .exec(request)
        case .input: return .input(payload)
        case .resize:
            guard payload.count == 4 else { throw .malformed("resize") }
            return .resize(rows: integer(payload, at: 0), columns: integer(payload, at: 2))
        case .signal:
            guard payload.count == 4 else { throw .malformed("signal") }
            return .signal(integer(payload, at: 0))
        case .started:
            guard payload.isEmpty else { throw .malformed("started") }
            return .started
        case .output: return .output(payload)
        case .errorOutput: return .errorOutput(payload)
        case .exit:
            guard payload.count == 4 else { throw .malformed("exit") }
            return .exit(integer(payload, at: 0))
        case .failure: return .failure(String(decoding: payload, as: UTF8.self))
        }
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func integer<T: FixedWidthInteger>(_ data: Data, at offset: Int) -> T {
        var value: T = 0
        for byte in data.dropFirst(offset).prefix(MemoryLayout<T>.size) {
            value = (value << 8) | T(truncatingIfNeeded: byte)
        }
        return value
    }
}

/// Incremental frame reader. Refuses an oversized length from the header
/// alone, before the payload is buffered.
public struct MacVMFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func next() throws(MacVMProtocolError) -> MacVMFrame? {
        guard buffer.count >= 5 else { return nil }
        let start = buffer.startIndex
        let kind = buffer[start]
        let length = buffer[(start + 1)..<(start + 5)].reduce(0) { ($0 << 8) | Int($1) }
        guard length <= MacVMFrame.maxPayloadBytes else { throw .oversized(length) }
        guard buffer.count >= 5 + length else { return nil }
        let payload = Data(buffer[(start + 5)..<(start + 5 + length)])
        buffer = Data(buffer.dropFirst(5 + length))
        return try MacVMFrame.decode(kind: kind, payload: payload)
    }
}

/// The command a session runs. The agent re-validates every field: the
/// host is trusted, but the check keeps a malformed request from reaching
/// `mount` or `execve`.
public struct MacVMExecRequest: Codable, Sendable, Equatable {
    public let version: Int
    /// Host path of the workspace share; also the guest mount point and cwd.
    public let workspace: String
    public let arguments: [String]
    /// `NAME=value` entries, complete: the agent adds nothing.
    public let environment: [String]
    public let terminal: Bool
    public let rows: UInt16
    public let columns: UInt16
    /// Guest 127.0.0.1 ports relayed to the same host ports.
    public let relayPorts: [Int]
    /// SBPL applied with `sandbox-exec` around the command.
    public let sandboxProfile: String

    public init(
        workspace: String,
        arguments: [String],
        environment: [String],
        terminal: Bool,
        rows: UInt16,
        columns: UInt16,
        relayPorts: [Int],
        sandboxProfile: String
    ) {
        self.version = MacVMAgent.protocolVersion
        self.workspace = workspace
        self.arguments = arguments
        self.environment = environment
        self.terminal = terminal
        self.rows = rows
        self.columns = columns
        self.relayPorts = relayPorts
        self.sandboxProfile = sandboxProfile
    }

    /// Guest directories the root agent must never mount the workspace at,
    /// under or over: the system, the agent and its session key, launchd
    /// and sudo configuration, and the guest user's home.
    static let guestSystemRoots = [
        "/System", "/Library", "/Applications", "/bin", "/sbin", "/usr", "/etc", "/private/etc",
        "/var/root", "/private/var/root", "/var/db", "/private/var/db", "/var/run", "/private/var/run",
        "/dev", "/cores", "/Users/\(MacVMAgent.user)",
    ]

    /// The guest system directory `workspace` would cover: one it is at or
    /// under, or one under it. Compared as the guest volume names files:
    /// normalization-insensitive, with full case folding (`ſ` is `s`).
    static func coveredSystemRoot(_ workspace: String) -> String? {
        let path = volumeComponents(workspace)
        return guestSystemRoots.first { root in
            let root = volumeComponents(root)
            return path.starts(with: root) || root.starts(with: path)
        }
    }

    /// Path components as the guest volume compares them.
    static func volumeComponents(_ path: String) -> [String] {
        components(path).map { $0.decomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil) }
    }

    /// Splits on the `/` byte, as the filesystem does. Swift's Character
    /// split would not: `/` plus a combining mark is a single Character.
    static func components(_ path: String) -> [String] {
        path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }

    /// True for `/a/b`: no empty, `.` or `..` components, no trailing `/`.
    static func isCanonical(_ path: String) -> Bool {
        let components = components(path)
        return components.count > 1 && components.first == ""
            && components.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Nil when acceptable, otherwise the reason.
    public func validated() -> String? {
        guard version == MacVMAgent.protocolVersion else {
            return "agent protocol \(version) is not \(MacVMAgent.protocolVersion); re-run rv-macvm prepare"
        }
        let all = [workspace, sandboxProfile] + arguments + environment
        guard all.allSatisfy({ !$0.contains("\0") }) else { return "request contains NUL" }
        guard Self.isCanonical(workspace) else {
            return "workspace must be a canonical absolute path below /: \(workspace)"
        }
        if let root = Self.coveredSystemRoot(workspace) {
            return "workspace \(workspace) would cover the guest system directory \(root)"
        }
        guard let executable = arguments.first, executable.hasPrefix("/") else {
            return "arguments must start with an absolute executable"
        }
        for entry in environment {
            guard let equals = entry.firstIndex(of: "="), GuestEnvironment.isValidName(String(entry[..<equals])) else {
                return "environment entry is not NAME=value"
            }
        }
        guard relayPorts.count <= RunOptions.maxRelayPorts,
            relayPorts.allSatisfy({ (1...65535).contains($0) }),
            Set(relayPorts).count == relayPorts.count
        else { return "relay ports must be at most \(RunOptions.maxRelayPorts) distinct values in 1...65535" }
        guard !sandboxProfile.isEmpty else { return "sandbox profile is empty" }
        let size = MacVMSession.encode(self).utf8.count
        guard size <= MacVMSession.maxEncodedBytes else {
            return "request is too large for the guest session: \(size) bytes encoded, at most \(MacVMSession.maxEncodedBytes)"
        }
        return nil
    }
}

extension GuestEnvironment {
    /// Environment of a macOS guest command: rv's macOS defaults, then the
    /// forwarded values (read from `RV_GUEST_<NAME>`).
    public static func macOS(forwarded names: [String], host: [String: String], terminal: Bool) -> [String] {
        build(
            image: [],
            forwarded: names,
            host: host,
            terminal: terminal,
            defaults: [
                ("PATH", MacVMAgent.defaultPath),
                ("HOME", "/Users/\(MacVMAgent.user)"),
                ("USER", MacVMAgent.user),
                ("LOGNAME", MacVMAgent.user),
                ("SHELL", "/bin/zsh"),
                ("LANG", "en_US.UTF-8"),
                ("TMPDIR", "/tmp"),
            ]
        )
    }
}
