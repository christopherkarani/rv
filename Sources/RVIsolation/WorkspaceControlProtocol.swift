import Foundation
import RVDomain

/// Bounds for the workspace attach protocol. A local client cannot raise them.
///
/// Launch arguments fit real developer command lines: a single `sh -c`
/// script, compiler invocation, or test-runner filter may use up to
/// `maxArgumentBytes` bytes, and a launch may carry up to `maxArguments`
/// of them, as long as the whole frame stays within `maxBodyBytes`.
/// Anything larger fails before send as `requestTooLarge`, never as an
/// opaque host rejection.
public enum WorkspaceControlLimits {
    public static let version = 1
    public static let name = "rv.workspace.v1"
    public static let maxBodyBytes = 65_536
    public static let maxExecutableBytes = 1_024
    public static let maxArgumentBytes = 8_192
    public static let maxArguments = 64
    public static let maxResourceProfileIDBytes = 64
    public static let maxRuntimes = 64
    public static let maxProjectBytes = 1_024
    public static let maxErrorBytes = 64
    /// Bounded operator-legible denial detail. Carries names from the
    /// operator's own policy file (link names, credential destinations) and,
    /// for `publishRejected`, the retained image path the operator needs to
    /// recover their work. Never internal error text.
    public static let maxDetailBytes = 256
    public static let maxHookBytes = 32
    public static let maxOperationBytes = 64
    public static let maxFeatures = 32
    public static let maxFeatureBytes = 64
    public static let maxConnections = 32
    public static let describeTimeoutSeconds: TimeInterval = 5
    public static let launchTimeoutSeconds: TimeInterval = 60
    public static let closeTimeoutSeconds: TimeInterval = 120
    public static let connectTimeoutSeconds: TimeInterval = 3
}

/// Closed set of attach-protocol failures. No internal Swift error text;
/// the optional `detail` field carries only policy-authored names.
public enum WorkspaceControlCode: String, Error, Sendable, Equatable, Codable {
    case workspaceClosing
    case workspaceClosed
    case runtimeNotFound
    case invalidRequest
    /// The operation is reserved for the prepare→permit→redeem ceremony
    /// and never executes directly. Scoped operator permits are not
    /// issued yet, so this denial is currently unconditional.
    case requiresOperatorPermit
    case resourceProfileUnavailable
    case resourceStagingFailed
    case incompatibleProtocol
    case unauthorizedClient
    case recoveryRequired
    case childTeardownFailed
    case runtimeLimit
    /// Close did not publish. The `detail` is the path of the retained disk
    /// image, then `workspacePublishRejectedSeparator` and the reason.
    case publishRejected
    case terminalUnavailable
    case terminalBusy
    case terminalLimit
    case terminalPrefixCommitted
}

public enum WorkspaceControlOp: String, Sendable, Equatable {
    case hello
    case capabilities
    case ping
    case describeWorkspace
    case listRuntimes
    case launchRuntime
    case launchAgentRuntime
    case launchCustomRuntime
    case ensureTerminalRuntime
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
    case terminalReplayBegin
    case terminalReplay
    case terminalReplayEnd
    case terminalOutput
    case terminalInputOwner
    case terminalWindow
    case runtimeExited
    case terminalOverflow
}

enum WorkspaceControlFeature {
    static let ensureTerminalRuntime = "ensureTerminalRuntime"
    static let identityAgentLaunchV1 = "identityAgentLaunchV1"
    /// Resize requests are accepted only from the connection holding input.
    static let resizeLeaseAuthority = "resizeLeaseAuthority"
    static let runtimeResourceProfilesV1 = "runtimeResourceProfilesV1"
    static let terminalReplayBatchesV1 = "terminalReplayBatchesV1"
    /// `launchRuntime` accepts `microvm`: run the command in a Linux micro-VM.
    static let microVMLaunchV1 = "microVMLaunchV1"
    /// A subscriber opts in by naming this feature in its subscribe request.
    /// The host sends `terminalWindow` only to opted-in subscribers, so an
    /// older client (whose reader fails closed on unknown ops) never sees it.
    static let terminalWindowNoticesV1 = "terminalWindowNoticesV1"
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
    /// True when this request created the runtime instead of reusing one.
    public var created: Bool

    public init(
        runtime: UUID,
        hook: String?,
        running: Bool,
        terminal: Bool = false,
        rows: Int? = nil,
        columns: Int? = nil,
        inputOwner: Bool = false,
        created: Bool = false
    ) {
        self.runtime = runtime
        self.hook = hook
        self.running = running
        self.terminal = terminal
        self.rows = rows
        self.columns = columns
        self.inputOwner = inputOwner
        self.created = created
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

/// Validated decode of a client→server frame.
public enum WorkspaceControlRequestDecode: Sendable, Equatable {
    case frame(WorkspaceControlRequestFrame)
    case incompatible
    case invalid
}

/// Validated decode of a server→client frame.
public enum WorkspaceControlResponseDecode: Sendable, Equatable {
    case frame(WorkspaceControlResponseFrame)
    case incompatible
    case invalid
}

/// `io` omitted or `discard` drops the runtime's output. `terminal` keeps a
/// host PTY. Any other value, or a size outside 1...512, fails closed.
func workspaceLaunchIO(
    io: String?,
    rows: Int?,
    columns: Int?
) -> Result<IsolatedIO, WorkspaceControlCode> {
    switch io {
    case nil, "discard":
        guard rows == nil, columns == nil else {
            return .failure(.invalidRequest)
        }
        return .success(.discard)
    case "terminal":
        guard let rows, let columns, TerminalStreamLimits.accepts(rows: rows, columns: columns) else {
            return .failure(.invalidRequest)
        }
        return .success(.pseudoTerminal(rows: rows, columns: columns))
    default:
        return .failure(.invalidRequest)
    }
}

/// The one wire codec module: every control frame crosses this seam
/// exactly once in each direction. Decode validates the envelope once
/// (body cap, version, key set, per-field limits) and yields the typed
/// per-op payload; encode takes the same payload. The body cap is a
/// wire-only property of `Data`, so it is enforced here on decode (and
/// on encode, where an over-cap frame must not be sent); per-field
/// limits run before any payload field is read.
enum WorkspaceControlCodec {
    private static let rootKeys: Set<String> = [
        "v", "id", "op", "token", "executable", "arguments", "runtime", "hook",
        "resourceProfileID", "agentDefinitionID", "customDefinitionDigest", "microvm", "ok", "error", "detail", "workspace", "host", "phase", "project", "runtimes",
        "attached", "running", "io", "rows", "cols", "sequence", "batch",
        "truncated", "replayLength", "bytes", "exit",
        "terminal", "input", "created", "features",
    ]

    static func decodeRequest(_ data: Data) -> WorkspaceControlRequestDecode {
        switch validatedEnvelope(data) {
        case .incompatible:
            .incompatible
        case .invalid:
            .invalid
        case .envelope(let envelope):
            .frame(WorkspaceControlRequestFrame(
                id: envelope.id,
                payload: requestPayload(envelope)
            ))
        }
    }

    static func decodeResponse(_ data: Data) -> WorkspaceControlResponseDecode {
        switch validatedEnvelope(data) {
        case .incompatible:
            .incompatible
        case .invalid:
            .invalid
        case .envelope(let envelope):
            .frame(WorkspaceControlResponseFrame(
                id: envelope.id,
                ok: envelope.ok,
                error: envelope.error,
                detail: envelope.detail,
                payload: responsePayload(envelope)
            ))
        }
    }

    static func encodeRequest(_ frame: WorkspaceControlRequestFrame) -> Data? {
        encode(envelope(frame))
    }

    static func encodeResponse(_ frame: WorkspaceControlResponseFrame) -> Data? {
        encode(envelope(frame))
    }

    /// The single validation pass both decode directions share.
    private enum Validated {
        case envelope(Envelope)
        case incompatible
        case invalid
    }

    private static func validatedEnvelope(_ data: Data) -> Validated {
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
        guard limitsValid(envelope) else {
            return .invalid
        }
        return .envelope(envelope)
    }

    /// Encode stays deliberately narrower than decode validation: the
    /// launch-shape fits plus the body cap. A peer decodes strictly, so
    /// an out-of-limit frame built in-process is refused there, exactly
    /// as with the legacy codec.
    private static func encode(_ envelope: Envelope) -> Data? {
        guard argumentsFit(envelope.arguments),
            resourceProfileIDFits(envelope.resourceProfileID),
            agentDefinitionIDFits(envelope.agentDefinitionID),
            customDefinitionDigestFits(envelope.customDefinitionDigest)
        else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(envelope),
            data.count <= WorkspaceControlLimits.maxBodyBytes
        else {
            return nil
        }
        return data
    }

    /// Size preflight for a launch, before encode. NUL content is not
    /// checked here; the host still refuses it as `invalidRequest`.
    static func launchFits(executable: String, arguments: [String]) -> Bool {
        executable.utf8.count <= WorkspaceControlLimits.maxExecutableBytes
            && arguments.count <= WorkspaceControlLimits.maxArguments
            && arguments.allSatisfy({ $0.utf8.count <= WorkspaceControlLimits.maxArgumentBytes })
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

    private static func limitsValid(_ envelope: Envelope) -> Bool {
        guard fits(envelope.op, WorkspaceControlLimits.maxOperationBytes),
            fits(envelope.executable, WorkspaceControlLimits.maxExecutableBytes),
            resourceProfileIDFits(envelope.resourceProfileID),
            agentDefinitionIDFits(envelope.agentDefinitionID),
            customDefinitionDigestFits(envelope.customDefinitionDigest),
            fits(envelope.hook, WorkspaceControlLimits.maxHookBytes),
            fits(envelope.error, WorkspaceControlLimits.maxErrorBytes),
            fits(envelope.detail, WorkspaceControlLimits.maxDetailBytes),
            fits(envelope.phase, 32),
            fits(envelope.project, WorkspaceControlLimits.maxProjectBytes),
            featuresFit(envelope.features),
            argumentsFit(envelope.arguments),
            attachedFits(envelope.attached),
            ioFits(envelope.io),
            dimensionFits(envelope.rows, maximum: TerminalStreamLimits.maximumRows),
            dimensionFits(envelope.columns, maximum: TerminalStreamLimits.maximumColumns),
            sequenceFits(envelope.sequence),
            replayLengthFits(envelope.replayLength),
            encodedBytesFit(envelope.bytes)
        else {
            return false
        }
        return runtimeWiresFit(envelope.runtimes)
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

    static func agentDefinitionIDFits(_ id: String?) -> Bool {
        guard let id else { return true }
        return AgentDefinitionID(validating: id) != nil
    }

    static func customDefinitionDigestFits(_ digest: String?) -> Bool {
        guard let digest else { return true }
        return digest.utf8.count == 64 && digest.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func resourceProfileIDFits(_ id: String?) -> Bool {
        guard let id else { return true }
        return !id.isEmpty && id.utf8.count <= WorkspaceControlLimits.maxResourceProfileIDBytes
            && id.utf8.allSatisfy {
                ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                    || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 95
            }
    }

    private static func runtimeWiresFit(_ values: [Envelope.RuntimeWire]?) -> Bool {
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

    private static func replayLengthFits(_ value: Int?) -> Bool {
        guard let value else { return true }
        return (0...TerminalStreamLimits.replayBytes).contains(value)
    }

    private static func encodedBytesFit(_ value: String?) -> Bool {
        guard let value else { return true }
        if value.isEmpty { return true }
        return TerminalBytesCodec.decode(value, maximum: TerminalStreamLimits.maximumInputBytes) != nil
    }

    private static func featuresFit(_ values: [String]?) -> Bool {
        guard let values else { return true }
        return values.count <= WorkspaceControlLimits.maxFeatures
            && values.allSatisfy {
                $0.utf8.count <= WorkspaceControlLimits.maxFeatureBytes && $0.contains("\0") == false
            }
    }

    // MARK: - Envelope ↔ payload mapping (the codec's one adapter table)

    private static func requestPayload(_ e: Envelope) -> WorkspaceControlRequestPayload {
        guard let op = WorkspaceControlOp(rawValue: e.op) else {
            return .unknown(rawOperation: e.op)
        }
        switch op {
        case .hello:
            return .hello(.init(token: e.token))
        case .capabilities:
            return .capabilities
        case .ping:
            return .ping
        case .describeWorkspace:
            return .describeWorkspace
        case .listRuntimes:
            return .listRuntimes
        case .launchRuntime:
            return .launchRuntime(launchFields(e))
        case .launchAgentRuntime:
            return .launchAgentRuntime(.init(
                agentDefinitionID: e.agentDefinitionID,
                arguments: e.arguments,
                io: e.io,
                rows: e.rows,
                columns: e.columns
            ))
        case .launchCustomRuntime:
            return .launchCustomRuntime(.init(
                executable: e.executable,
                arguments: e.arguments,
                customDefinitionDigest: e.customDefinitionDigest,
                io: e.io,
                rows: e.rows,
                columns: e.columns
            ))
        case .ensureTerminalRuntime:
            return .ensureTerminalRuntime(launchFields(e))
        case .cancelRuntime:
            return .cancelRuntime(.init(runtime: e.runtime))
        case .closeWorkspace:
            return .closeWorkspace
        case .detach:
            return .detach
        case .subscribeTerminal:
            return .subscribeTerminal(.init(runtime: e.runtime, features: e.features))
        case .unsubscribeTerminal:
            return .unsubscribeTerminal(.init(runtime: e.runtime))
        case .terminalInput:
            return .terminalInput(.init(runtime: e.runtime, bytes: e.bytes))
        case .acquireTerminalInput:
            return .acquireTerminalInput(.init(runtime: e.runtime))
        case .releaseTerminalInput:
            return .releaseTerminalInput(.init(runtime: e.runtime))
        case .resizeTerminal:
            return .resizeTerminal(.init(runtime: e.runtime, rows: e.rows, columns: e.columns))
        case .workspaceClosed, .terminalReplayBegin, .terminalReplay, .terminalReplayEnd,
            .terminalOutput, .terminalInputOwner, .terminalWindow,
            .runtimeExited, .terminalOverflow:
            return .unsupported(op)
        }
    }

    private static func launchFields(_ e: Envelope) -> WorkspaceControlRequestPayload.Launch {
        .init(
            executable: e.executable,
            arguments: e.arguments,
            resourceProfileID: e.resourceProfileID,
            microvm: e.microvm,
            hook: e.hook,
            io: e.io,
            rows: e.rows,
            columns: e.columns
        )
    }

    private static func envelope(_ frame: WorkspaceControlRequestFrame) -> Envelope {
        var e = Envelope(v: WorkspaceControlLimits.version, id: frame.id, op: frame.rawOperation)
        switch frame.payload {
        case .hello(let p):
            e.token = p.token
        case .capabilities, .ping, .describeWorkspace, .listRuntimes,
            .closeWorkspace, .detach, .unsupported, .unknown:
            break
        case .launchRuntime(let p), .ensureTerminalRuntime(let p):
            applyLaunchFields(p, to: &e)
        case .launchAgentRuntime(let p):
            e.agentDefinitionID = p.agentDefinitionID
            e.arguments = p.arguments
            e.io = p.io
            e.rows = p.rows
            e.columns = p.columns
        case .launchCustomRuntime(let p):
            e.executable = p.executable
            e.arguments = p.arguments
            e.customDefinitionDigest = p.customDefinitionDigest
            e.io = p.io
            e.rows = p.rows
            e.columns = p.columns
        case .cancelRuntime(let p), .unsubscribeTerminal(let p),
            .acquireTerminalInput(let p), .releaseTerminalInput(let p):
            e.runtime = p.runtime
        case .subscribeTerminal(let p):
            e.runtime = p.runtime
            e.features = p.features
        case .terminalInput(let p):
            e.runtime = p.runtime
            e.bytes = p.bytes
        case .resizeTerminal(let p):
            e.runtime = p.runtime
            e.rows = p.rows
            e.columns = p.columns
        }
        return e
    }

    private static func applyLaunchFields(
        _ p: WorkspaceControlRequestPayload.Launch,
        to e: inout Envelope
    ) {
        e.executable = p.executable
        e.arguments = p.arguments
        e.resourceProfileID = p.resourceProfileID
        e.microvm = p.microvm
        e.hook = p.hook
        e.io = p.io
        e.rows = p.rows
        e.columns = p.columns
    }

    private static func responsePayload(_ e: Envelope) -> WorkspaceControlResponsePayload {
        guard let op = WorkspaceControlOp(rawValue: e.op) else {
            return .unknown(rawOperation: e.op)
        }
        switch op {
        case .hello:
            return .hello(.init(workspace: e.workspace, host: e.host))
        case .capabilities:
            return .capabilities(.init(features: e.features))
        case .ping:
            return .ping(.init(host: e.host))
        case .describeWorkspace:
            return .describeWorkspace(workspaceFields(e))
        case .listRuntimes:
            return .listRuntimes(.init(runtimes: e.runtimes?.map(report(_:))))
        case .launchRuntime:
            return .launchRuntime(launchReplyFields(e))
        case .launchAgentRuntime:
            return .launchAgentRuntime(launchReplyFields(e))
        case .launchCustomRuntime:
            return .launchCustomRuntime(launchReplyFields(e))
        case .ensureTerminalRuntime:
            return .ensureTerminalRuntime(launchReplyFields(e))
        case .cancelRuntime:
            return .cancelRuntime(.init(runtime: e.runtime))
        case .closeWorkspace:
            return .closeWorkspace(workspaceFields(e))
        case .detach:
            return .detach
        case .workspaceClosed:
            return .workspaceClosed(workspaceFields(e))
        case .subscribeTerminal:
            return .subscribeTerminal(.init(
                runtime: e.runtime, rows: e.rows, columns: e.columns, terminal: e.terminal
            ))
        case .unsubscribeTerminal:
            return .unsubscribeTerminal(.init(runtime: e.runtime))
        case .terminalInput:
            return .terminalInput(.init(runtime: e.runtime))
        case .acquireTerminalInput:
            return .acquireTerminalInput(.init(runtime: e.runtime, inputOwner: e.inputOwner))
        case .releaseTerminalInput:
            return .releaseTerminalInput(.init(runtime: e.runtime, inputOwner: e.inputOwner))
        case .resizeTerminal:
            return .resizeTerminal(.init(runtime: e.runtime, rows: e.rows, columns: e.columns))
        case .terminalReplayBegin:
            return .terminalReplayBegin(.init(
                runtime: e.runtime, batch: e.batch,
                truncated: e.truncated, replayLength: e.replayLength
            ))
        case .terminalReplay:
            return .terminalReplay(.init(runtime: e.runtime, sequence: e.sequence, bytes: e.bytes))
        case .terminalReplayEnd:
            return .terminalReplayEnd(.init(runtime: e.runtime, batch: e.batch))
        case .terminalOutput:
            return .terminalOutput(.init(runtime: e.runtime, sequence: e.sequence, bytes: e.bytes))
        case .terminalInputOwner:
            return .terminalInputOwner(.init(runtime: e.runtime, inputOwner: e.inputOwner))
        case .terminalWindow:
            return .terminalWindow(.init(runtime: e.runtime, rows: e.rows, columns: e.columns))
        case .runtimeExited:
            return .runtimeExited(.init(
                runtime: e.runtime, running: e.running, exitStatus: e.exitStatus
            ))
        case .terminalOverflow:
            return .terminalOverflow(.init(runtime: e.runtime))
        }
    }

    private static func workspaceFields(_ e: Envelope) -> WorkspaceControlResponsePayload.Workspace {
        .init(
            workspace: e.workspace,
            host: e.host,
            phase: e.phase,
            project: e.project,
            attached: e.attached
        )
    }

    private static func launchReplyFields(_ e: Envelope) -> WorkspaceControlResponsePayload.Launch {
        .init(
            runtime: e.runtime,
            hook: e.hook,
            running: e.running,
            rows: e.rows,
            columns: e.columns,
            terminal: e.terminal,
            inputOwner: e.inputOwner,
            created: e.created
        )
    }

    private static func report(_ wire: Envelope.RuntimeWire) -> WorkspaceRuntimeReport {
        WorkspaceRuntimeReport(
            runtime: wire.runtime,
            hook: wire.hook,
            running: wire.running,
            terminal: wire.terminal,
            rows: wire.rows,
            columns: wire.columns,
            inputOwner: wire.inputOwner
        )
    }

    private static func envelope(_ frame: WorkspaceControlResponseFrame) -> Envelope {
        var e = Envelope(v: WorkspaceControlLimits.version, id: frame.id, op: frame.rawOperation)
        e.ok = frame.ok
        e.error = frame.error
        e.detail = frame.detail
        switch frame.payload {
        case .hello(let p):
            e.workspace = p.workspace
            e.host = p.host
        case .capabilities(let p):
            e.features = p.features
        case .ping(let p):
            e.host = p.host
        case .describeWorkspace(let p), .closeWorkspace(let p), .workspaceClosed(let p):
            applyWorkspaceFields(p, to: &e)
        case .listRuntimes(let p):
            e.runtimes = p.runtimes?.map {
                Envelope.RuntimeWire(
                    runtime: $0.runtime,
                    hook: $0.hook,
                    running: $0.running,
                    terminal: $0.terminal,
                    rows: $0.rows,
                    columns: $0.columns,
                    inputOwner: $0.inputOwner
                )
            }
        case .launchRuntime(let p), .launchAgentRuntime(let p),
            .launchCustomRuntime(let p), .ensureTerminalRuntime(let p):
            applyLaunchReplyFields(p, to: &e)
        case .cancelRuntime(let p), .unsubscribeTerminal(let p),
            .terminalInput(let p), .terminalOverflow(let p):
            e.runtime = p.runtime
        case .detach, .unknown:
            break
        case .subscribeTerminal(let p):
            e.runtime = p.runtime
            e.rows = p.rows
            e.columns = p.columns
            e.terminal = p.terminal
        case .acquireTerminalInput(let p), .releaseTerminalInput(let p),
            .terminalInputOwner(let p):
            e.runtime = p.runtime
            e.inputOwner = p.inputOwner
        case .resizeTerminal(let p), .terminalWindow(let p):
            e.runtime = p.runtime
            e.rows = p.rows
            e.columns = p.columns
        case .terminalReplayBegin(let p):
            e.runtime = p.runtime
            e.batch = p.batch
            e.truncated = p.truncated
            e.replayLength = p.replayLength
        case .terminalReplay(let p), .terminalOutput(let p):
            e.runtime = p.runtime
            e.sequence = p.sequence
            e.bytes = p.bytes
        case .terminalReplayEnd(let p):
            e.runtime = p.runtime
            e.batch = p.batch
        case .runtimeExited(let p):
            e.runtime = p.runtime
            e.running = p.running
            e.exitStatus = p.exitStatus
        }
        return e
    }

    private static func applyWorkspaceFields(
        _ p: WorkspaceControlResponsePayload.Workspace,
        to e: inout Envelope
    ) {
        e.workspace = p.workspace
        e.host = p.host
        e.phase = p.phase
        e.project = p.project
        e.attached = p.attached
    }

    private static func applyLaunchReplyFields(
        _ p: WorkspaceControlResponsePayload.Launch,
        to e: inout Envelope
    ) {
        e.runtime = p.runtime
        e.hook = p.hook
        e.running = p.running
        e.rows = p.rows
        e.columns = p.columns
        e.terminal = p.terminal
        e.inputOwner = p.inputOwner
        e.created = p.created
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

/// The wire shape: the codec module's private detail behind the payload
/// seam. Unknown keys and unknown versions fail closed. Only the codec
/// reads or writes this type.
private struct Envelope {
    var v: Int
    var id: UUID?
    var op: String
    var token: UUID? = nil
    var executable: String? = nil
    var arguments: [String]? = nil
    var resourceProfileID: String? = nil
    var agentDefinitionID: String? = nil
    var customDefinitionDigest: String? = nil
    var microvm: MicroVMLaunchOptions? = nil
    var runtime: UUID? = nil
    var hook: String? = nil
    var ok: Bool? = nil
    var error: String? = nil
    var detail: String? = nil
    var workspace: UUID? = nil
    var host: UUID? = nil
    var phase: String? = nil
    var project: String? = nil
    var runtimes: [RuntimeWire]? = nil
    var attached: Int? = nil
    var running: Bool? = nil
    var io: String? = nil
    var rows: Int? = nil
    var columns: Int? = nil
    var sequence: Int64? = nil
    var batch: UUID? = nil
    var truncated: Bool? = nil
    var replayLength: Int? = nil
    var bytes: String? = nil
    var exitStatus: Int32? = nil
    var terminal: Bool? = nil
    var inputOwner: Bool? = nil
    var created: Bool? = nil
    var features: [String]? = nil

    struct RuntimeWire {
        var runtime: UUID
        var hook: String?
        var running: Bool
        var terminal: Bool = false
        var rows: Int? = nil
        var columns: Int? = nil
        var inputOwner: Bool = false
    }

    enum CodingKeys: String, CodingKey {
        case v
        case id
        case op
        case token
        case executable
        case arguments
        case resourceProfileID
        case agentDefinitionID
        case customDefinitionDigest
        case microvm
        case runtime
        case hook
        case ok
        case error
        case detail
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
        case batch
        case truncated
        case replayLength
        case bytes
        case exitStatus = "exit"
        case terminal
        case inputOwner = "input"
        case created
        case features
    }
}

extension Envelope.RuntimeWire: Codable {
    enum CodingKeys: String, CodingKey {
        case runtime
        case hook
        case running
        case terminal
        case rows
        case cols
        case input
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

extension Envelope: Codable {
    init(from decoder: Decoder) throws {
        let keys = try KeyScan(from: decoder)
        guard keys.keys.isSubset(of: [
            "v", "id", "op", "token", "executable", "arguments", "runtime", "hook",
            "resourceProfileID", "agentDefinitionID", "customDefinitionDigest", "microvm", "ok", "error", "detail", "workspace", "host", "phase", "project", "runtimes",
            "attached", "running", "io", "rows", "cols", "sequence", "batch",
            "truncated", "replayLength", "bytes", "exit",
            "terminal", "input", "created", "features",
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
        resourceProfileID = try container.decodeIfPresent(String.self, forKey: .resourceProfileID)
        agentDefinitionID = try container.decodeIfPresent(String.self, forKey: .agentDefinitionID)
        customDefinitionDigest = try container.decodeIfPresent(String.self, forKey: .customDefinitionDigest)
        microvm = try container.decodeIfPresent(MicroVMLaunchOptions.self, forKey: .microvm)
        runtime = try container.decodeIfPresent(UUID.self, forKey: .runtime)
        hook = try container.decodeIfPresent(String.self, forKey: .hook)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
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
        batch = try container.decodeIfPresent(UUID.self, forKey: .batch)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated)
        replayLength = try container.decodeIfPresent(Int.self, forKey: .replayLength)
        bytes = try container.decodeIfPresent(String.self, forKey: .bytes)
        exitStatus = try container.decodeIfPresent(Int32.self, forKey: .exitStatus)
        terminal = try container.decodeIfPresent(Bool.self, forKey: .terminal)
        inputOwner = try container.decodeIfPresent(Bool.self, forKey: .inputOwner)
        created = try container.decodeIfPresent(Bool.self, forKey: .created)
        features = try container.decodeIfPresent([String].self, forKey: .features)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(op, forKey: .op)
        try container.encodeIfPresent(token, forKey: .token)
        try container.encodeIfPresent(executable, forKey: .executable)
        try container.encodeIfPresent(arguments, forKey: .arguments)
        try container.encodeIfPresent(resourceProfileID, forKey: .resourceProfileID)
        try container.encodeIfPresent(agentDefinitionID, forKey: .agentDefinitionID)
        try container.encodeIfPresent(customDefinitionDigest, forKey: .customDefinitionDigest)
        try container.encodeIfPresent(microvm, forKey: .microvm)
        try container.encodeIfPresent(runtime, forKey: .runtime)
        try container.encodeIfPresent(hook, forKey: .hook)
        try container.encodeIfPresent(ok, forKey: .ok)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(detail, forKey: .detail)
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
        try container.encodeIfPresent(batch, forKey: .batch)
        try container.encodeIfPresent(truncated, forKey: .truncated)
        try container.encodeIfPresent(replayLength, forKey: .replayLength)
        try container.encodeIfPresent(bytes, forKey: .bytes)
        try container.encodeIfPresent(exitStatus, forKey: .exitStatus)
        try container.encodeIfPresent(terminal, forKey: .terminal)
        try container.encodeIfPresent(inputOwner, forKey: .inputOwner)
        try container.encodeIfPresent(created, forKey: .created)
        try container.encodeIfPresent(features, forKey: .features)
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
    case .unknownRuntime, .unknownPreparedLaunch, .redemptionAlreadyAccepted:
        .runtimeNotFound
    case .childTeardownFailed:
        .childTeardownFailed
    case .publishRejected:
        .publishRejected
    case .runtimeLimit:
        .runtimeLimit
    case .ownedByLiveProcess, .recoveryInProgress, .unresolvedWorkspace:
        .recoveryRequired
    case .apply(.resourceStagingFailed):
        .resourceStagingFailed
    case .apply, .cleanupFailed, .preparationFailed:
        .invalidRequest
    }
}

/// The operator-facing detail that travels with `workspaceControlCode`.
func workspaceControlDetail(_ error: WorkspaceSessionError) -> String? {
    if case .publishRejected(let image, let reason) = error {
        return reason.isEmpty ? image : image + workspacePublishRejectedSeparator + reason
    }
    return nil
}

/// Joins the retained image path and the reason in a `publishRejected`
/// detail. Control characters are stripped on the wire, so it is printable;
/// the image path is generated under the temp directory and never holds it.
/// The image comes first so the wire bound truncates only the reason.
let workspacePublishRejectedSeparator = " :: "

/// Splits a `publishRejected` detail into the image path and the reason.
func workspacePublishRejectedDetail(_ detail: String?) -> (image: String, reason: String) {
    guard let detail else { return ("", "") }
    guard let range = detail.range(of: workspacePublishRejectedSeparator) else { return (detail, "") }
    return (String(detail[..<range.lowerBound]), String(detail[range.upperBound...]))
}
