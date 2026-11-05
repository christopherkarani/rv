import Foundation

// Per-op payloads for the workspace control wire: the deep seam of the
// codec module. `WorkspaceControlCodec` validates a frame once and yields
// one of these typed payloads; encode takes the same payload back. Callers
// cross this interface instead of assembling optional field bags per op,
// so a wire-field change lands in one place with locality at the seam.
// A payload carries exactly the fields its op defines, still optional
// where the receiving handler adjudicates presence — decode stays as
// lenient per op as the legacy handlers were, and the wire bytes an
// adapter emits are unchanged.

/// One validated client→server frame: correlation id plus typed payload.
public struct WorkspaceControlRequestFrame: Sendable, Equatable {

    public var id: UUID?
    public var payload: WorkspaceControlRequestPayload

    public init(id: UUID? = nil, payload: WorkspaceControlRequestPayload) {
        self.id = id
        self.payload = payload
    }

    /// Nil only for the explicit unknown-op case; `rawOperation` echoes it.
    public var operation: WorkspaceControlOp? { payload.operation }
    /// Exact wire op for failure echoes. Never dispatch on this.
    public var rawOperation: String { payload.rawOperation }
}

/// Typed payload for one client→server operation.
public enum WorkspaceControlRequestPayload: Sendable, Equatable {

    public struct Hello: Sendable, Equatable {
        public var token: UUID?
        public init(token: UUID? = nil) { self.token = token }
    }

    /// Launch fields shared by `launchRuntime` and
    /// `ensureTerminalRuntime`; each op's handler validates them.
    public struct Launch: Sendable, Equatable {
        public var executable: String?
        public var arguments: [String]?
        public var resourceProfileID: String?
        public var microvm: MicroVMLaunchOptions?
        public var hook: String?
        public var io: String?
        public var rows: Int?
        public var columns: Int?

        public init(
            executable: String? = nil,
            arguments: [String]? = nil,
            resourceProfileID: String? = nil,
            microvm: MicroVMLaunchOptions? = nil,
            hook: String? = nil,
            io: String? = nil,
            rows: Int? = nil,
            columns: Int? = nil
        ) {
            self.executable = executable
            self.arguments = arguments
            self.resourceProfileID = resourceProfileID
            self.microvm = microvm
            self.hook = hook
            self.io = io
            self.rows = rows
            self.columns = columns
        }
    }

    public struct LaunchAgent: Sendable, Equatable {
        public var agentDefinitionID: String?
        public var arguments: [String]?
        public var io: String?
        public var rows: Int?
        public var columns: Int?

        public init(
            agentDefinitionID: String? = nil,
            arguments: [String]? = nil,
            io: String? = nil,
            rows: Int? = nil,
            columns: Int? = nil
        ) {
            self.agentDefinitionID = agentDefinitionID
            self.arguments = arguments
            self.io = io
            self.rows = rows
            self.columns = columns
        }
    }

    public struct LaunchCustom: Sendable, Equatable {
        public var executable: String?
        public var arguments: [String]?
        public var customDefinitionDigest: String?
        public var io: String?
        public var rows: Int?
        public var columns: Int?

        public init(
            executable: String? = nil,
            arguments: [String]? = nil,
            customDefinitionDigest: String? = nil,
            io: String? = nil,
            rows: Int? = nil,
            columns: Int? = nil
        ) {
            self.executable = executable
            self.arguments = arguments
            self.customDefinitionDigest = customDefinitionDigest
            self.io = io
            self.rows = rows
            self.columns = columns
        }
    }

    /// The runtime an op addresses (cancel/unsubscribe/acquire/release).
    public struct RuntimeRef: Sendable, Equatable {
        public var runtime: UUID?
        public init(runtime: UUID? = nil) { self.runtime = runtime }
    }

    public struct Subscribe: Sendable, Equatable {
        public var runtime: UUID?
        public var features: [String]?
        public init(runtime: UUID? = nil, features: [String]? = nil) {
            self.runtime = runtime
            self.features = features
        }
    }

    public struct TerminalInput: Sendable, Equatable {
        public var runtime: UUID?
        /// Base64 PTY input (`TerminalBytesCodec`).
        public var bytes: String?
        public init(runtime: UUID? = nil, bytes: String? = nil) {
            self.runtime = runtime
            self.bytes = bytes
        }
    }

    public struct Resize: Sendable, Equatable {
        public var runtime: UUID?
        public var rows: Int?
        public var columns: Int?
        public init(runtime: UUID? = nil, rows: Int? = nil, columns: Int? = nil) {
            self.runtime = runtime
            self.rows = rows
            self.columns = columns
        }
    }

    case hello(Hello)
    case capabilities
    case ping
    case describeWorkspace
    case listRuntimes
    case launchRuntime(Launch)
    case launchAgentRuntime(LaunchAgent)
    case launchCustomRuntime(LaunchCustom)
    case ensureTerminalRuntime(Launch)
    case cancelRuntime(RuntimeRef)
    case closeWorkspace
    case detach
    case subscribeTerminal(Subscribe)
    case unsubscribeTerminal(RuntimeRef)
    case terminalInput(TerminalInput)
    case acquireTerminalInput(RuntimeRef)
    case releaseTerminalInput(RuntimeRef)
    case resizeTerminal(Resize)
    /// A known server→client op sent by a client; the host refuses it
    /// after the same authorization check every known op gets.
    case unsupported(WorkspaceControlOp)
    /// An op this build does not know. Kept explicit so the host can
    /// echo the raw op in its failure reply.
    case unknown(rawOperation: String)

    public var operation: WorkspaceControlOp? {
        switch self {
        case .hello: .hello
        case .capabilities: .capabilities
        case .ping: .ping
        case .describeWorkspace: .describeWorkspace
        case .listRuntimes: .listRuntimes
        case .launchRuntime: .launchRuntime
        case .launchAgentRuntime: .launchAgentRuntime
        case .launchCustomRuntime: .launchCustomRuntime
        case .ensureTerminalRuntime: .ensureTerminalRuntime
        case .cancelRuntime: .cancelRuntime
        case .closeWorkspace: .closeWorkspace
        case .detach: .detach
        case .subscribeTerminal: .subscribeTerminal
        case .unsubscribeTerminal: .unsubscribeTerminal
        case .terminalInput: .terminalInput
        case .acquireTerminalInput: .acquireTerminalInput
        case .releaseTerminalInput: .releaseTerminalInput
        case .resizeTerminal: .resizeTerminal
        case .unsupported(let op): op
        case .unknown: nil
        }
    }

    public var rawOperation: String {
        switch self {
        case .hello: WorkspaceControlOp.hello.rawValue
        case .capabilities: WorkspaceControlOp.capabilities.rawValue
        case .ping: WorkspaceControlOp.ping.rawValue
        case .describeWorkspace: WorkspaceControlOp.describeWorkspace.rawValue
        case .listRuntimes: WorkspaceControlOp.listRuntimes.rawValue
        case .launchRuntime: WorkspaceControlOp.launchRuntime.rawValue
        case .launchAgentRuntime: WorkspaceControlOp.launchAgentRuntime.rawValue
        case .launchCustomRuntime: WorkspaceControlOp.launchCustomRuntime.rawValue
        case .ensureTerminalRuntime: WorkspaceControlOp.ensureTerminalRuntime.rawValue
        case .cancelRuntime: WorkspaceControlOp.cancelRuntime.rawValue
        case .closeWorkspace: WorkspaceControlOp.closeWorkspace.rawValue
        case .detach: WorkspaceControlOp.detach.rawValue
        case .subscribeTerminal: WorkspaceControlOp.subscribeTerminal.rawValue
        case .unsubscribeTerminal: WorkspaceControlOp.unsubscribeTerminal.rawValue
        case .terminalInput: WorkspaceControlOp.terminalInput.rawValue
        case .acquireTerminalInput: WorkspaceControlOp.acquireTerminalInput.rawValue
        case .releaseTerminalInput: WorkspaceControlOp.releaseTerminalInput.rawValue
        case .resizeTerminal: WorkspaceControlOp.resizeTerminal.rawValue
        case .unsupported(let op): op.rawValue
        case .unknown(let raw): raw
        }
    }
}

/// One validated server→client frame. `ok`/`error`/`detail` are
/// envelope-level outcome fields, uniform across ops like `id`; the
/// payload carries only the op's own fields. Failure replies carry an
/// empty payload for the echoed op, exactly like the legacy wire shape.
public struct WorkspaceControlResponseFrame: Sendable, Equatable {

    public var id: UUID?
    public var ok: Bool?
    public var error: String?
    public var detail: String?
    public var payload: WorkspaceControlResponsePayload

    public init(
        id: UUID? = nil,
        ok: Bool? = nil,
        error: String? = nil,
        detail: String? = nil,
        payload: WorkspaceControlResponsePayload
    ) {
        self.id = id
        self.ok = ok
        self.error = error
        self.detail = detail
        self.payload = payload
    }

    /// Nil only for the explicit unknown-op case; `rawOperation` echoes it.
    public var operation: WorkspaceControlOp? { payload.operation }
    /// Exact wire op for echoes. Never dispatch on this.
    public var rawOperation: String { payload.rawOperation }
    /// Typed view of `error`; nil when absent or unknown.
    public var code: WorkspaceControlCode? {
        get { error.flatMap(WorkspaceControlCode.init(rawValue:)) }
        set { error = newValue?.rawValue }
    }

    /// Failure echoing the incoming request's wire op, even when unknown.
    public static func failure(
        request: WorkspaceControlRequestFrame,
        code: WorkspaceControlCode,
        detail: String? = nil
    ) -> WorkspaceControlResponseFrame {
        WorkspaceControlResponseFrame(
            id: request.id,
            ok: false,
            error: code.rawValue,
            detail: detail.map(boundedDenialDetail),
            payload: .empty(echoing: request.rawOperation)
        )
    }

    /// Failure for a known operation; unknown-op echoes use the
    /// `request:` overload.
    public static func failure(
        id: UUID?,
        operation: WorkspaceControlOp,
        code: WorkspaceControlCode
    ) -> WorkspaceControlResponseFrame {
        WorkspaceControlResponseFrame(
            id: id,
            ok: false,
            error: code.rawValue,
            payload: .empty(for: operation)
        )
    }

    /// Clamp denial detail to the wire bound on a scalar boundary and
    /// strip control characters: the detail renders in client chrome,
    /// where control bytes must never become terminal control.
    static func boundedDenialDetail(_ raw: String) -> String {
        let filtered = String(raw.unicodeScalars.filter {
            CharacterSet.controlCharacters.contains($0) == false
        })
        var cut = filtered
        while cut.utf8.count > WorkspaceControlLimits.maxDetailBytes, cut.isEmpty == false {
            cut.removeLast()
        }
        return cut
    }
}

/// Typed payload for one server→client operation (reply or event).
public enum WorkspaceControlResponsePayload: Sendable, Equatable {

    public struct Hello: Sendable, Equatable {
        public var workspace: UUID?
        public var host: UUID?
        public init(workspace: UUID? = nil, host: UUID? = nil) {
            self.workspace = workspace
            self.host = host
        }
    }

    public struct Capabilities: Sendable, Equatable {
        public var features: [String]?
        public init(features: [String]? = nil) { self.features = features }
    }

    public struct Ping: Sendable, Equatable {
        public var host: UUID?
        public init(host: UUID? = nil) { self.host = host }
    }

    /// Workspace description shared by describe/close/workspaceClosed.
    public struct Workspace: Sendable, Equatable {
        public var workspace: UUID?
        public var host: UUID?
        public var phase: String?
        public var project: String?
        public var attached: Int?

        public init(
            workspace: UUID? = nil,
            host: UUID? = nil,
            phase: String? = nil,
            project: String? = nil,
            attached: Int? = nil
        ) {
            self.workspace = workspace
            self.host = host
            self.phase = phase
            self.project = project
            self.attached = attached
        }
    }

    public struct ListRuntimes: Sendable, Equatable {
        public var runtimes: [WorkspaceRuntimeReport]?
        public init(runtimes: [WorkspaceRuntimeReport]? = nil) { self.runtimes = runtimes }
    }

    /// Launch outcome shared by the launch family replies.
    public struct Launch: Sendable, Equatable {
        public var runtime: UUID?
        public var hook: String?
        public var running: Bool?
        public var rows: Int?
        public var columns: Int?
        public var terminal: Bool?
        public var inputOwner: Bool?
        public var created: Bool?

        public init(
            runtime: UUID? = nil,
            hook: String? = nil,
            running: Bool? = nil,
            rows: Int? = nil,
            columns: Int? = nil,
            terminal: Bool? = nil,
            inputOwner: Bool? = nil,
            created: Bool? = nil
        ) {
            self.runtime = runtime
            self.hook = hook
            self.running = running
            self.rows = rows
            self.columns = columns
            self.terminal = terminal
            self.inputOwner = inputOwner
            self.created = created
        }
    }

    /// Bare runtime acknowledgement (cancel/unsubscribe/input/overflow).
    public struct RuntimeRef: Sendable, Equatable {
        public var runtime: UUID?
        public init(runtime: UUID? = nil) { self.runtime = runtime }
    }

    public struct Subscribe: Sendable, Equatable {
        public var runtime: UUID?
        public var rows: Int?
        public var columns: Int?
        public var terminal: Bool?

        public init(
            runtime: UUID? = nil,
            rows: Int? = nil,
            columns: Int? = nil,
            terminal: Bool? = nil
        ) {
            self.runtime = runtime
            self.rows = rows
            self.columns = columns
            self.terminal = terminal
        }
    }

    /// Input-owner state (acquire/release replies and the owner event).
    public struct InputOwner: Sendable, Equatable {
        public var runtime: UUID?
        public var inputOwner: Bool?
        public init(runtime: UUID? = nil, inputOwner: Bool? = nil) {
            self.runtime = runtime
            self.inputOwner = inputOwner
        }
    }

    /// Terminal dimensions (resize reply and the window event).
    public struct Window: Sendable, Equatable {
        public var runtime: UUID?
        public var rows: Int?
        public var columns: Int?
        public init(runtime: UUID? = nil, rows: Int? = nil, columns: Int? = nil) {
            self.runtime = runtime
            self.rows = rows
            self.columns = columns
        }
    }

    public struct ReplayBegin: Sendable, Equatable {
        public var runtime: UUID?
        public var batch: UUID?
        public var truncated: Bool?
        public var replayLength: Int?

        public init(
            runtime: UUID? = nil,
            batch: UUID? = nil,
            truncated: Bool? = nil,
            replayLength: Int? = nil
        ) {
            self.runtime = runtime
            self.batch = batch
            self.truncated = truncated
            self.replayLength = replayLength
        }
    }

    /// One sequenced chunk of PTY bytes (replay and live output).
    public struct Chunk: Sendable, Equatable {
        public var runtime: UUID?
        public var sequence: Int64?
        /// Base64 PTY bytes (`TerminalBytesCodec`).
        public var bytes: String?

        public init(runtime: UUID? = nil, sequence: Int64? = nil, bytes: String? = nil) {
            self.runtime = runtime
            self.sequence = sequence
            self.bytes = bytes
        }
    }

    public struct ReplayEnd: Sendable, Equatable {
        public var runtime: UUID?
        public var batch: UUID?
        public init(runtime: UUID? = nil, batch: UUID? = nil) {
            self.runtime = runtime
            self.batch = batch
        }
    }

    public struct RuntimeExited: Sendable, Equatable {
        public var runtime: UUID?
        public var running: Bool?
        public var exitStatus: Int32?

        public init(runtime: UUID? = nil, running: Bool? = nil, exitStatus: Int32? = nil) {
            self.runtime = runtime
            self.running = running
            self.exitStatus = exitStatus
        }
    }

    case hello(Hello)
    case capabilities(Capabilities)
    case ping(Ping)
    case describeWorkspace(Workspace)
    case listRuntimes(ListRuntimes)
    case launchRuntime(Launch)
    case launchAgentRuntime(Launch)
    case launchCustomRuntime(Launch)
    case ensureTerminalRuntime(Launch)
    case cancelRuntime(RuntimeRef)
    case closeWorkspace(Workspace)
    case detach
    case workspaceClosed(Workspace)
    case subscribeTerminal(Subscribe)
    case unsubscribeTerminal(RuntimeRef)
    case terminalInput(RuntimeRef)
    case acquireTerminalInput(InputOwner)
    case releaseTerminalInput(InputOwner)
    case resizeTerminal(Window)
    case terminalReplayBegin(ReplayBegin)
    case terminalReplay(Chunk)
    case terminalReplayEnd(ReplayEnd)
    case terminalOutput(Chunk)
    case terminalInputOwner(InputOwner)
    case terminalWindow(Window)
    case runtimeExited(RuntimeExited)
    case terminalOverflow(RuntimeRef)
    /// An op this build does not know, kept explicit so adapters fail
    /// closed on it instead of misreading another op's fields.
    case unknown(rawOperation: String)

    public var operation: WorkspaceControlOp? {
        switch self {
        case .hello: .hello
        case .capabilities: .capabilities
        case .ping: .ping
        case .describeWorkspace: .describeWorkspace
        case .listRuntimes: .listRuntimes
        case .launchRuntime: .launchRuntime
        case .launchAgentRuntime: .launchAgentRuntime
        case .launchCustomRuntime: .launchCustomRuntime
        case .ensureTerminalRuntime: .ensureTerminalRuntime
        case .cancelRuntime: .cancelRuntime
        case .closeWorkspace: .closeWorkspace
        case .detach: .detach
        case .workspaceClosed: .workspaceClosed
        case .subscribeTerminal: .subscribeTerminal
        case .unsubscribeTerminal: .unsubscribeTerminal
        case .terminalInput: .terminalInput
        case .acquireTerminalInput: .acquireTerminalInput
        case .releaseTerminalInput: .releaseTerminalInput
        case .resizeTerminal: .resizeTerminal
        case .terminalReplayBegin: .terminalReplayBegin
        case .terminalReplay: .terminalReplay
        case .terminalReplayEnd: .terminalReplayEnd
        case .terminalOutput: .terminalOutput
        case .terminalInputOwner: .terminalInputOwner
        case .terminalWindow: .terminalWindow
        case .runtimeExited: .runtimeExited
        case .terminalOverflow: .terminalOverflow
        case .unknown: nil
        }
    }

    public var rawOperation: String {
        switch self {
        case .hello: WorkspaceControlOp.hello.rawValue
        case .capabilities: WorkspaceControlOp.capabilities.rawValue
        case .ping: WorkspaceControlOp.ping.rawValue
        case .describeWorkspace: WorkspaceControlOp.describeWorkspace.rawValue
        case .listRuntimes: WorkspaceControlOp.listRuntimes.rawValue
        case .launchRuntime: WorkspaceControlOp.launchRuntime.rawValue
        case .launchAgentRuntime: WorkspaceControlOp.launchAgentRuntime.rawValue
        case .launchCustomRuntime: WorkspaceControlOp.launchCustomRuntime.rawValue
        case .ensureTerminalRuntime: WorkspaceControlOp.ensureTerminalRuntime.rawValue
        case .cancelRuntime: WorkspaceControlOp.cancelRuntime.rawValue
        case .closeWorkspace: WorkspaceControlOp.closeWorkspace.rawValue
        case .detach: WorkspaceControlOp.detach.rawValue
        case .workspaceClosed: WorkspaceControlOp.workspaceClosed.rawValue
        case .subscribeTerminal: WorkspaceControlOp.subscribeTerminal.rawValue
        case .unsubscribeTerminal: WorkspaceControlOp.unsubscribeTerminal.rawValue
        case .terminalInput: WorkspaceControlOp.terminalInput.rawValue
        case .acquireTerminalInput: WorkspaceControlOp.acquireTerminalInput.rawValue
        case .releaseTerminalInput: WorkspaceControlOp.releaseTerminalInput.rawValue
        case .resizeTerminal: WorkspaceControlOp.resizeTerminal.rawValue
        case .terminalReplayBegin: WorkspaceControlOp.terminalReplayBegin.rawValue
        case .terminalReplay: WorkspaceControlOp.terminalReplay.rawValue
        case .terminalReplayEnd: WorkspaceControlOp.terminalReplayEnd.rawValue
        case .terminalOutput: WorkspaceControlOp.terminalOutput.rawValue
        case .terminalInputOwner: WorkspaceControlOp.terminalInputOwner.rawValue
        case .terminalWindow: WorkspaceControlOp.terminalWindow.rawValue
        case .runtimeExited: WorkspaceControlOp.runtimeExited.rawValue
        case .terminalOverflow: WorkspaceControlOp.terminalOverflow.rawValue
        case .unknown(let raw): raw
        }
    }

    /// The runtime this payload addresses, when its op names one.
    var runtime: UUID? {
        switch self {
        case .launchRuntime(let p), .launchAgentRuntime(let p),
            .launchCustomRuntime(let p), .ensureTerminalRuntime(let p):
            p.runtime
        case .cancelRuntime(let p), .unsubscribeTerminal(let p),
            .terminalInput(let p), .terminalOverflow(let p):
            p.runtime
        case .subscribeTerminal(let p):
            p.runtime
        case .acquireTerminalInput(let p), .releaseTerminalInput(let p),
            .terminalInputOwner(let p):
            p.runtime
        case .resizeTerminal(let p), .terminalWindow(let p):
            p.runtime
        case .terminalReplayBegin(let p):
            p.runtime
        case .terminalReplay(let p), .terminalOutput(let p):
            p.runtime
        case .terminalReplayEnd(let p):
            p.runtime
        case .runtimeExited(let p):
            p.runtime
        case .hello, .capabilities, .ping, .describeWorkspace, .listRuntimes,
            .closeWorkspace, .detach, .workspaceClosed, .unknown:
            nil
        }
    }

    /// Field-less payload for `op`, used by failure replies whose wire
    /// shape carries only the envelope outcome fields.
    static func empty(for op: WorkspaceControlOp) -> WorkspaceControlResponsePayload {
        switch op {
        case .hello: .hello(Hello())
        case .capabilities: .capabilities(Capabilities())
        case .ping: .ping(Ping())
        case .describeWorkspace: .describeWorkspace(Workspace())
        case .listRuntimes: .listRuntimes(ListRuntimes())
        case .launchRuntime: .launchRuntime(Launch())
        case .launchAgentRuntime: .launchAgentRuntime(Launch())
        case .launchCustomRuntime: .launchCustomRuntime(Launch())
        case .ensureTerminalRuntime: .ensureTerminalRuntime(Launch())
        case .cancelRuntime: .cancelRuntime(RuntimeRef())
        case .closeWorkspace: .closeWorkspace(Workspace())
        case .detach: .detach
        case .workspaceClosed: .workspaceClosed(Workspace())
        case .subscribeTerminal: .subscribeTerminal(Subscribe())
        case .unsubscribeTerminal: .unsubscribeTerminal(RuntimeRef())
        case .terminalInput: .terminalInput(RuntimeRef())
        case .acquireTerminalInput: .acquireTerminalInput(InputOwner())
        case .releaseTerminalInput: .releaseTerminalInput(InputOwner())
        case .resizeTerminal: .resizeTerminal(Window())
        case .terminalReplayBegin: .terminalReplayBegin(ReplayBegin())
        case .terminalReplay: .terminalReplay(Chunk())
        case .terminalReplayEnd: .terminalReplayEnd(ReplayEnd())
        case .terminalOutput: .terminalOutput(Chunk())
        case .terminalInputOwner: .terminalInputOwner(InputOwner())
        case .terminalWindow: .terminalWindow(Window())
        case .runtimeExited: .runtimeExited(RuntimeExited())
        case .terminalOverflow: .terminalOverflow(RuntimeRef())
        }
    }

    /// Field-less payload echoing a raw wire op, known or unknown.
    static func empty(echoing rawOperation: String) -> WorkspaceControlResponsePayload {
        guard let op = WorkspaceControlOp(rawValue: rawOperation) else {
            return .unknown(rawOperation: rawOperation)
        }
        return .empty(for: op)
    }
}
