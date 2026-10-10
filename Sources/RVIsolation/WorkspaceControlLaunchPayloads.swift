import Foundation
import RVDomain

// Launch-family parse layer (T5/C04 pilot): typed payloads above the
// WorkspaceControlMessage envelope. The envelope stays the wire format;
// this layer adds no bytes. Each payload is constructible only valid,
// and every refusal code matches the legacy per-op guards exactly.

/// Validated `launchRuntime` fields: an absolute command, resolved IO, an
/// optional hook participant, and the resolved resource profile (nil selects
/// the base fence).
struct LaunchRuntimePayload: Sendable, Equatable {
    var command: IsolatedCommand
    var io: IsolatedIO
    var hook: HookHost?
    var resourceProfile: RuntimeResourceProfile?

    /// Ordered exactly like the legacy handler: executable, profile, hook,
    /// command, IO. The profile lookup precedes hook/command/IO selection,
    /// so a doubly-faulty message reports resourceProfileUnavailable.
    static func parse(
        _ request: WorkspaceControlRequest,
        resourcePolicy: RuntimeResourcePolicy,
        project: String
    ) -> Result<LaunchRuntimePayload, WorkspaceControlCode> {
        guard let executable = request.executable, executable.hasPrefix("/") else {
            return .failure(.invalidRequest)
        }
        // Explicit selection only: a missing ID always means the base fence.
        // The policy's defaultProfile is a UI hint the host never consults.
        let resourceProfile: RuntimeResourceProfile?
        if let id = request.resourceProfileID {
            guard let selected = resourcePolicy.profile(id: id, project: project) else {
                return .failure(.resourceProfileUnavailable)
            }
            resourceProfile = selected
        } else {
            resourceProfile = nil
        }
        let hook: HookHost?
        switch legacyLaunchHookSelection(request.hook) {
        case .failure(let code):
            return .failure(code)
        case .success(let selected):
            hook = selected
        }
        guard let command = IsolatedCommand(
            executable: executable,
            arguments: request.arguments ?? []
        ) else {
            return .failure(.invalidRequest)
        }
        switch workspaceLaunchIO(io: request.io, rows: request.rows, columns: request.columns) {
        case .failure(let code):
            return .failure(code)
        case .success(let io):
            return .success(LaunchRuntimePayload(
                command: command,
                io: io,
                hook: hook,
                resourceProfile: resourceProfile
            ))
        }
    }
}

/// Validated `ensureTerminalRuntime` fields: a launch that must carry a PTY.
/// The profile ID stays raw: the existing-runtime shortcut is
/// profile-agnostic and creation re-adjudicates through the launch path.
struct EnsureTerminalRuntimePayload: Sendable, Equatable {
    var command: IsolatedCommand
    var io: IsolatedIO
    var hook: HookHost?
    var resourceProfileID: String?

    /// Structural parse only (no policy lookup). Mirrors the legacy single
    /// guard: absolute command, well-formed hook, terminal IO.
    static func parse(
        _ request: WorkspaceControlRequest
    ) -> Result<EnsureTerminalRuntimePayload, WorkspaceControlCode> {
        guard let executable = request.executable, executable.hasPrefix("/"),
            let command = IsolatedCommand(
                executable: executable,
                arguments: request.arguments ?? []
            )
        else {
            return .failure(.invalidRequest)
        }
        let hook: HookHost?
        switch legacyLaunchHookSelection(request.hook) {
        case .failure(let code):
            return .failure(code)
        case .success(let selected):
            hook = selected
        }
        switch workspaceLaunchIO(io: request.io, rows: request.rows, columns: request.columns) {
        case .success(let io):
            guard case .pseudoTerminal = io else {
                return .failure(.invalidRequest)
            }
            return .success(EnsureTerminalRuntimePayload(
                command: command,
                io: io,
                hook: hook,
                resourceProfileID: request.resourceProfileID
            ))
        case .failure(let code):
            return .failure(code)
        }
    }
}

/// Validated `cancelRuntime` fields: the runtime to cancel.
struct CancelRuntimePayload: Sendable, Equatable {
    var runtime: UUID

    static func parse(
        _ request: WorkspaceControlRequest
    ) -> Result<CancelRuntimePayload, WorkspaceControlCode> {
        guard let runtime = request.runtime else {
            return .failure(.invalidRequest)
        }
        return .success(CancelRuntimePayload(runtime: runtime))
    }
}

/// `launchAgentRuntime` fields. The prepare→permit→redeem door consumes no
/// fields, so construction is infallible: any validation here would turn
/// today's requiresOperatorPermit into invalidRequest. Carries the op's
/// contract for the future direct-launch path.
struct LaunchAgentRuntimePayload: Sendable, Equatable {
    var agentDefinitionID: String?
    var arguments: [String]
    var io: String?
    var rows: Int?
    var columns: Int?

    init(_ request: WorkspaceControlRequest) {
        agentDefinitionID = request.agentDefinitionID
        arguments = request.arguments ?? []
        io = request.io
        rows = request.rows
        columns = request.columns
    }
}

/// `launchCustomRuntime` fields. Infallible like the agent door: the deny
/// consumes no fields and any validation would change the refusal code.
struct LaunchCustomRuntimePayload: Sendable, Equatable {
    var executable: String?
    var arguments: [String]
    var customDefinitionDigest: String?
    var io: String?
    var rows: Int?
    var columns: Int?

    init(_ request: WorkspaceControlRequest) {
        executable = request.executable
        arguments = request.arguments ?? []
        customDefinitionDigest = request.customDefinitionDigest
        io = request.io
        rows = request.rows
        columns = request.columns
    }
}

/// Typed launch-family request. The server dispatches on these cases;
/// unmigrated ops keep the bag path untouched.
enum WorkspaceControlLaunchRequest: Sendable, Equatable {
    case launchRuntime(LaunchRuntimePayload)
    case launchAgentRuntime(LaunchAgentRuntimePayload)
    case launchCustomRuntime(LaunchCustomRuntimePayload)
    case ensureTerminalRuntime(EnsureTerminalRuntimePayload)
    case cancelRuntime(CancelRuntimePayload)

    /// Supervisor-held context the launch parse consults. Only the
    /// launchRuntime arm uses it; the other arms parse structurally.
    struct Context: Sendable {
        var resourcePolicy: RuntimeResourcePolicy
        var project: String
    }

    /// Typed parse for the launch family. Nil when `request` names an
    /// unmigrated op. The switch is exhaustive so a future op must choose
    /// the typed path or the bag path deliberately.
    static func parse(
        _ request: WorkspaceControlRequest,
        context: Context
    ) -> Result<WorkspaceControlLaunchRequest, WorkspaceControlCode>? {
        switch request.operation {
        case .launchRuntime:
            return LaunchRuntimePayload.parse(
                request,
                resourcePolicy: context.resourcePolicy,
                project: context.project
            ).map(WorkspaceControlLaunchRequest.launchRuntime)
        case .launchAgentRuntime:
            return .success(.launchAgentRuntime(LaunchAgentRuntimePayload(request)))
        case .launchCustomRuntime:
            return .success(.launchCustomRuntime(LaunchCustomRuntimePayload(request)))
        case .ensureTerminalRuntime:
            return EnsureTerminalRuntimePayload.parse(request)
                .map(WorkspaceControlLaunchRequest.ensureTerminalRuntime)
        case .cancelRuntime:
            return CancelRuntimePayload.parse(request)
                .map(WorkspaceControlLaunchRequest.cancelRuntime)
        case .none,
            .hello,
            .capabilities,
            .ping,
            .describeWorkspace,
            .listRuntimes,
            .closeWorkspace,
            .detach,
            .workspaceClosed,
            .subscribeTerminal,
            .unsubscribeTerminal,
            .terminalInput,
            .acquireTerminalInput,
            .releaseTerminalInput,
            .resizeTerminal,
            .terminalReplayBegin,
            .terminalReplay,
            .terminalReplayEnd,
            .terminalOutput,
            .terminalInputOwner,
            .terminalWindow,
            .runtimeExited,
            .terminalOverflow:
            return nil
        }
    }
}

/// Maps the legacy launch wire's hook field to protocol participation.
///
/// Step 8 (F2): a well-formed tag that names a `HookHost` selects hook
/// protocol handling; any other well-formed tag is accepted but selects
/// nothing. Malformed tags are refused. The result feeds hook protocol
/// only — staging selection is definition-derived (`launchLegacy` takes
/// no tag), so no wire value can select credentials.
func legacyLaunchHookSelection(_ raw: String?) -> Result<HookHost?, WorkspaceControlCode> {
    guard let raw else { return .success(nil) }
    guard AgentTagValidator.isValid(raw) else { return .failure(.invalidRequest) }
    return .success(HookHost(rawValue: raw))
}
