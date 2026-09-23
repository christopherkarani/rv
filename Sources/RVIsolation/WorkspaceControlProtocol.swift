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
}

/// One runtime as a control client may see it.
public struct WorkspaceRuntimeReport: Sendable, Equatable {
    public var runtime: UUID
    public var hook: String?
    public var running: Bool

    public init(runtime: UUID, hook: String?, running: Bool) {
        self.runtime = runtime
        self.hook = hook
        self.running = running
    }
}

struct WorkspaceRuntimeFact: Sendable, Equatable {
    var id: UUID
    var hookHost: String?
    var running: Bool
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
        "attached", "running",
    ]
    private static let runtimeKeys: Set<String> = ["runtime", "hook", "running"]

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
            attachedFits(envelope.attached)
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

    struct RuntimeWire: Codable {
        var runtime: UUID
        var hook: String?
        var running: Bool

        enum CodingKeys: String, CodingKey {
            case runtime
            case hook
            case running
        }

        init(runtime: UUID, hook: String?, running: Bool) {
            self.runtime = runtime
            self.hook = hook
            self.running = running
        }

        init(from decoder: Decoder) throws {
            let keys = try KeyScan(from: decoder)
            guard keys.keys.isSubset(of: ["runtime", "hook", "running"]) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unknown runtime field")
                )
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            runtime = try container.decode(UUID.self, forKey: .runtime)
            hook = try container.decodeIfPresent(String.self, forKey: .hook)
            running = try container.decode(Bool.self, forKey: .running)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(runtime, forKey: .runtime)
            try container.encodeIfPresent(hook, forKey: .hook)
            try container.encode(running, forKey: .running)
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
    }

    init(from decoder: Decoder) throws {
        let keys = try KeyScan(from: decoder)
        guard keys.keys.isSubset(of: [
            "v", "id", "op", "token", "executable", "arguments", "runtime", "hook",
            "ok", "error", "workspace", "host", "phase", "project", "runtimes",
            "attached", "running",
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
            RuntimeWire(runtime: $0.runtime, hook: $0.hook, running: $0.running)
        }
        attached = message.attached
        running = message.running
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
                WorkspaceRuntimeReport(runtime: $0.runtime, hook: $0.hook, running: $0.running)
            },
            attached: attached,
            running: running
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
    case .ownedByLiveProcess, .recoveryInProgress, .unresolvedWorkspace:
        .recoveryRequired
    case .apply, .cleanupFailed:
        .invalidRequest
    }
}
