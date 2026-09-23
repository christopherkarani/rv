import Foundation
import RVDomain

/// Bounds for the workspace attach protocol. A local client cannot raise them.
public enum WorkspaceControlLimits {
    public static let version = 1
    public static let name = "rv.workspace.v1"
    public static let maxBodyBytes = 16_384
    public static let maxExecutableBytes = 1_024
    public static let maxArgumentBytes = 256
    public static let maxArguments = 16
    public static let maxRuntimes = 64
    public static let maxProjectBytes = 1_024
    public static let maxErrorBytes = 64
    public static let maxHookBytes = 32
    public static let maxOperationBytes = 64
    public static let maxConnections = 32
    public static let describeTimeoutSeconds: TimeInterval = 5
    public static let launchTimeoutSeconds: TimeInterval = 60
    public static let closeTimeoutSeconds: TimeInterval = 120
    public static let connectTimeoutSeconds: TimeInterval = 3
}

/// Closed set of attach-protocol failures. No internal Swift error text.
public enum WorkspaceControlCode: String, Error, Sendable, Equatable, Codable {
    case workspaceClosing
    case workspaceClosed
    case runtimeNotFound
    case invalidRequest
    case incompatibleProtocol
    case unauthorizedClient
    case recoveryRequired
    case childTeardownFailed
    case runtimeLimit
    case terminalUnavailable
    case terminalBusy
    case terminalLimit
}

public enum WorkspaceControlOp: String, Sendable, Equatable {
    case hello
    case ping
    case describeWorkspace
    case listRuntimes
    case launchRuntime
    case cancelRuntime
    case closeWorkspace
    case detach
    case workspaceClosed
    case subscribeTerminal
    case unsubscribeTerminal
    case terminalInput
    case acquireTerminalInput
    case releaseTerminalInput
    case resizeTerminal
    case terminalReplay
    case terminalOutput
    case terminalInputOwner
    case runtimeExited
    case terminalOverflow
}

/// One runtime as a control client may see it.
public struct WorkspaceRuntimeReport: Sendable, Equatable {
    public var runtime: UUID
    public var hook: String?
    public var running: Bool
    /// The runtime has a host-owned PTY. File descriptors stay on the host.
    public var terminal: Bool
    public var rows: Int?
    public var columns: Int?
    /// Some attached client currently holds terminal input.
    public var inputOwner: Bool

    public init(
        runtime: UUID,
        hook: String?,
        running: Bool,
        terminal: Bool = false,
        rows: Int? = nil,
        columns: Int? = nil,
        inputOwner: Bool = false
    ) {
        self.runtime = runtime
        self.hook = hook
        self.running = running
        self.terminal = terminal
        self.rows = rows
        self.columns = columns
        self.inputOwner = inputOwner
    }
}

struct WorkspaceRuntimeFact: Sendable, Equatable {
    var id: UUID
    var hookHost: String?
    var running: Bool
    var terminal: Bool
    var rows: Int?
    var columns: Int?
    var inputOwner: Bool
}

struct WorkspaceOwnerCredential: Sendable, Equatable {
    var token: UUID
    var lockPath: String
    var lockDevice: UInt64
    var lockInode: UInt64
}

/// One versioned control message. Unknown keys and unknown versions fail closed.
struct WorkspaceControlMessage: Sendable, Equatable {
    var version: Int
    var id: UUID?
    var op: String
    var token: UUID?
    var executable: String?
    var arguments: [String]?
    var runtime: UUID?
    var hook: String?
    var ok: Bool?
    var error: String?
    var workspace: UUID?
    var host: UUID?
    var phase: String?
    var project: String?
    var runtimes: [WorkspaceRuntimeReport]?
    var attached: Int?
    var running: Bool?
    var io: String?
    var rows: Int?
    var columns: Int?
    var sequence: Int64?
    var bytes: String?
    var exitStatus: Int32?
    var terminal: Bool?
    var inputOwner: Bool?

    static func error(
        id: UUID?,
        op: String,
        code: WorkspaceControlCode
    ) -> WorkspaceControlMessage {
        WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: id,
            op: op,
            ok: false,
            error: code.rawValue
        )
    }
}

enum WorkspaceControlDecode: Equatable, Sendable {
    case message(WorkspaceControlMessage)
    case incompatible
    case invalid
}

enum WorkspaceControlCodec {
    private static let rootKeys: Set<String> = [
        "v", "id", "op", "token", "executable", "arguments", "runtime", "hook",
        "ok", "error", "workspace", "host", "phase", "project", "runtimes",
        "attached", "running", "io", "rows", "cols", "sequence", "bytes", "exit",
        "terminal", "input",
    ]
    private static let runtimeKeys: Set<String> = [
        "runtime", "hook", "running", "terminal", "rows", "cols", "input",
    ]

    static func decode(_ data: Data) -> WorkspaceControlDecode {
        guard data.isEmpty == false, data.count <= WorkspaceControlLimits.maxBodyBytes else {
            return .invalid
        }
        let decoder = JSONDecoder()
        guard let scanned = try? decoder.decode(KeyScan.self, from: data),
            scanned.keys.isSubset(of: rootKeys),
            let envelope = try? decoder.decode(Envelope.self, from: data)
        else {
            return .invalid
        }
        guard envelope.v == WorkspaceControlLimits.version else {
            return .incompatible
        }
        guard fits(envelope.op, WorkspaceControlLimits.maxOperationBytes),
            fits(envelope.executable, WorkspaceControlLimits.maxExecutableBytes),
            fits(envelope.hook, WorkspaceControlLimits.maxHookBytes),
            fits(envelope.error, WorkspaceControlLimits.maxErrorBytes),
            fits(envelope.phase, 32),
            fits(envelope.project, WorkspaceControlLimits.maxProjectBytes),
            argumentsFit(envelope.arguments),
            attachedFits(envelope.attached),
            ioFits(envelope.io),
            dimensionFits(envelope.rows, maximum: TerminalStreamLimits.maximumRows),
            dimensionFits(envelope.columns, maximum: TerminalStreamLimits.maximumColumns),
            sequenceFits(envelope.sequence),
            encodedBytesFit(envelope.bytes)
        else {
            return .invalid
        }
        let message = envelope.message
        guard runtimesFit(message.runtimes) else { return .invalid }
        return .message(message)
    }

    static func encode(_ message: WorkspaceControlMessage) -> Data? {
        let envelope = Envelope(message)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(envelope),
            data.count <= WorkspaceControlLimits.maxBodyBytes
        else {
            return nil
        }
        return data
    }

    static func headerCount(_ header: Data) -> Result<Int, WorkspaceControlCode> {
        guard header.count == 4 else { return .failure(.invalidRequest) }
        let declared = header.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(as: UInt32.self).bigEndian
        }
        guard declared > 0, declared <= UInt32(WorkspaceControlLimits.maxBodyBytes) else {
            return .failure(.invalidRequest)
        }
        return .success(Int(declared))
    }

    private static func fits(_ value: String?, _ limit: Int) -> Bool {
        guard let value else { return true }
        return value.utf8.count <= limit && value.contains("\0") == false
    }

    private static func argumentsFit(_ values: [String]?) -> Bool {
        guard let values else { return true }
        guard values.count <= WorkspaceControlLimits.maxArguments else { return false }
        return values.allSatisfy {
            $0.utf8.count <= WorkspaceControlLimits.maxArgumentBytes && $0.contains("\0") == false
        }
    }

    private static func runtimesFit(_ values: [WorkspaceRuntimeReport]?) -> Bool {
        guard let values else { return true }
        guard values.count <= WorkspaceControlLimits.maxRuntimes else { return false }
        return values.allSatisfy { fits($0.hook, WorkspaceControlLimits.maxHookBytes) }
    }

    private static func attachedFits(_ value: Int?) -> Bool {
        guard let value else { return true }
        return value >= 0 && value <= WorkspaceControlLimits.maxConnections
    }

    private static func ioFits(_ value: String?) -> Bool {
        guard let value else { return true }
        return value == "discard" || value == "terminal"
    }

    private static func dimensionFits(_ value: Int?, maximum: Int) -> Bool {
        guard let value else { return true }
        return value >= TerminalStreamLimits.minimumDimension && value <= maximum
    }

    private static func sequenceFits(_ value: Int64?) -> Bool {
        guard let value else { return true }
        return value >= 0
    }

    private static func encodedBytesFit(_ value: String?) -> Bool {
        guard let value else { return true }
        if value.isEmpty { return true }
        return TerminalBytesCodec.decode(value, maximum: TerminalStreamLimits.maximumInputBytes) != nil
    }
}

private struct KeyScan: Decodable {
    var keys: Set<String>

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        keys = Set(container.allKeys.map(\.stringValue))
    }
}

private struct Envelope: Codable {
    var v: Int
    var id: UUID?
    var op: String
    var token: UUID?
    var executable: String?
    var arguments: [String]?
    var runtime: UUID?
    var hook: String?
    var ok: Bool?
    var error: String?
    var workspace: UUID?
    var host: UUID?
    var phase: String?
    var project: String?
    var runtimes: [RuntimeWire]?
    var attached: Int?
    var running: Bool?
    var io: String?
    var rows: Int?
    var columns: Int?
    var sequence: Int64?
    var bytes: String?
    var exitStatus: Int32?
    var terminal: Bool?
    var inputOwner: Bool?

    struct RuntimeWire: Codable {
        var runtime: UUID
        var hook: String?
        var running: Bool
        var terminal: Bool
        var rows: Int?
        var columns: Int?
        var inputOwner: Bool

        enum CodingKeys: String, CodingKey {
            case runtime
            case hook
            case running
            case terminal
            case rows
            case cols
            case input
        }

        init(
            runtime: UUID,
            hook: String?,
            running: Bool,
            terminal: Bool = false,
            rows: Int? = nil,
            columns: Int? = nil,
            inputOwner: Bool = false
        ) {
            self.runtime = runtime
            self.hook = hook
            self.running = running
            self.terminal = terminal
            self.rows = rows
            self.columns = columns
            self.inputOwner = inputOwner
        }

        init(from decoder: Decoder) throws {
            let keys = try KeyScan(from: decoder)
            guard keys.keys.isSubset(of: [
                "runtime", "hook", "running", "terminal", "rows", "cols", "input",
            ]) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unknown runtime field")
                )
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            runtime = try container.decode(UUID.self, forKey: .runtime)
            hook = try container.decodeIfPresent(String.self, forKey: .hook)
            running = try container.decode(Bool.self, forKey: .running)
            terminal = try container.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
            rows = try container.decodeIfPresent(Int.self, forKey: .rows)
            columns = try container.decodeIfPresent(Int.self, forKey: .cols)
            inputOwner = try container.decodeIfPresent(Bool.self, forKey: .input) ?? false
            if let rows,
                (TerminalStreamLimits.minimumDimension...TerminalStreamLimits.maximumRows).contains(rows) == false
            {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "rows")
                )
            }
            if let columns,
                (TerminalStreamLimits.minimumDimension...TerminalStreamLimits.maximumColumns).contains(columns)
                    == false
            {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "columns")
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(runtime, forKey: .runtime)
            try container.encodeIfPresent(hook, forKey: .hook)
            try container.encode(running, forKey: .running)
            try container.encode(terminal, forKey: .terminal)
            try container.encodeIfPresent(rows, forKey: .rows)
            try container.encodeIfPresent(columns, forKey: .cols)
            try container.encode(inputOwner, forKey: .input)
        }
    }

    enum CodingKeys: String, CodingKey {
        case v
        case id
        case op
        case token
        case executable
        case arguments
        case runtime
        case hook
        case ok
        case error
        case workspace
        case host
        case phase
        case project
        case runtimes
        case attached
        case running
        case io
        case rows
        case columns = "cols"
        case sequence
        case bytes
        case exitStatus = "exit"
        case terminal
        case inputOwner = "input"
    }

    init(from decoder: Decoder) throws {
        let keys = try KeyScan(from: decoder)
        guard keys.keys.isSubset(of: [
            "v", "id", "op", "token", "executable", "arguments", "runtime", "hook",
            "ok", "error", "workspace", "host", "phase", "project", "runtimes",
            "attached", "running", "io", "rows", "cols", "sequence", "bytes", "exit",
        "terminal", "input",
        ]) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown field")
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        op = try container.decode(String.self, forKey: .op)
        token = try container.decodeIfPresent(UUID.self, forKey: .token)
        executable = try container.decodeIfPresent(String.self, forKey: .executable)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments)
        runtime = try container.decodeIfPresent(UUID.self, forKey: .runtime)
        hook = try container.decodeIfPresent(String.self, forKey: .hook)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        workspace = try container.decodeIfPresent(UUID.self, forKey: .workspace)
        host = try container.decodeIfPresent(UUID.self, forKey: .host)
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        runtimes = try container.decodeIfPresent([RuntimeWire].self, forKey: .runtimes)
        attached = try container.decodeIfPresent(Int.self, forKey: .attached)
        running = try container.decodeIfPresent(Bool.self, forKey: .running)
        io = try container.decodeIfPresent(String.self, forKey: .io)
        rows = try container.decodeIfPresent(Int.self, forKey: .rows)
        columns = try container.decodeIfPresent(Int.self, forKey: .columns)
        sequence = try container.decodeIfPresent(Int64.self, forKey: .sequence)
        bytes = try container.decodeIfPresent(String.self, forKey: .bytes)
        exitStatus = try container.decodeIfPresent(Int32.self, forKey: .exitStatus)
        terminal = try container.decodeIfPresent(Bool.self, forKey: .terminal)
        inputOwner = try container.decodeIfPresent(Bool.self, forKey: .inputOwner)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(op, forKey: .op)
        try container.encodeIfPresent(token, forKey: .token)
        try container.encodeIfPresent(executable, forKey: .executable)
        try container.encodeIfPresent(arguments, forKey: .arguments)
        try container.encodeIfPresent(runtime, forKey: .runtime)
        try container.encodeIfPresent(hook, forKey: .hook)
        try container.encodeIfPresent(ok, forKey: .ok)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(workspace, forKey: .workspace)
        try container.encodeIfPresent(host, forKey: .host)
        try container.encodeIfPresent(phase, forKey: .phase)
        try container.encodeIfPresent(project, forKey: .project)
        try container.encodeIfPresent(runtimes, forKey: .runtimes)
        try container.encodeIfPresent(attached, forKey: .attached)
        try container.encodeIfPresent(running, forKey: .running)
        try container.encodeIfPresent(io, forKey: .io)
        try container.encodeIfPresent(rows, forKey: .rows)
        try container.encodeIfPresent(columns, forKey: .columns)
        try container.encodeIfPresent(sequence, forKey: .sequence)
        try container.encodeIfPresent(bytes, forKey: .bytes)
        try container.encodeIfPresent(exitStatus, forKey: .exitStatus)
        try container.encodeIfPresent(terminal, forKey: .terminal)
        try container.encodeIfPresent(inputOwner, forKey: .inputOwner)
    }

    init(_ message: WorkspaceControlMessage) {
        v = message.version
        id = message.id
        op = message.op
        token = message.token
        executable = message.executable
        arguments = message.arguments
        runtime = message.runtime
        hook = message.hook
        ok = message.ok
        error = message.error
        workspace = message.workspace
        host = message.host
        phase = message.phase
        project = message.project
        runtimes = message.runtimes?.map {
            RuntimeWire(
                runtime: $0.runtime,
                hook: $0.hook,
                running: $0.running,
                terminal: $0.terminal,
                rows: $0.rows,
                columns: $0.columns,
                inputOwner: $0.inputOwner
            )
        }
        attached = message.attached
        running = message.running
        io = message.io
        rows = message.rows
        columns = message.columns
        sequence = message.sequence
        bytes = message.bytes
        exitStatus = message.exitStatus
        terminal = message.terminal
        inputOwner = message.inputOwner
    }

    var message: WorkspaceControlMessage {
        WorkspaceControlMessage(
            version: v,
            id: id,
            op: op,
            token: token,
            executable: executable,
            arguments: arguments,
            runtime: runtime,
            hook: hook,
            ok: ok,
            error: error,
            workspace: workspace,
            host: host,
            phase: phase,
            project: project,
            runtimes: runtimes?.map {
                WorkspaceRuntimeReport(
                    runtime: $0.runtime,
                    hook: $0.hook,
                    running: $0.running,
                    terminal: $0.terminal,
                    rows: $0.rows,
                    columns: $0.columns,
                    inputOwner: $0.inputOwner
                )
            },
            attached: attached,
            running: running,
            io: io,
            rows: rows,
            columns: columns,
            sequence: sequence,
            bytes: bytes,
            exitStatus: exitStatus,
            terminal: terminal,
            inputOwner: inputOwner
        )
    }
}

func workspaceControlCode(_ error: WorkspaceSessionError) -> WorkspaceControlCode {
    switch error {
    case .notAcceptingRuntime(.closing):
        .workspaceClosing
    case .notAcceptingRuntime(.closed), .alreadyClosed:
        .workspaceClosed
    case .notAcceptingRuntime:
        .invalidRequest
    case .unknownRuntime:
        .runtimeNotFound
    case .childTeardownFailed:
        .childTeardownFailed
    case .runtimeLimit:
        .runtimeLimit
    case .ownedByLiveProcess, .recoveryInProgress, .unresolvedWorkspace:
        .recoveryRequired
    case .apply, .cleanupFailed:
        .invalidRequest
    }
}
