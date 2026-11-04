import Foundation
import RVDomain

// Launch-family validation layer: parses the codec's per-op payloads
// into validated launch values. Each payload is constructible only
// valid, and every refusal code matches the legacy per-op guards
// exactly.

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
        _ fields: WorkspaceControlRequestPayload.Launch,
        resourcePolicy: RuntimeResourcePolicy,
        project: String
    ) -> Result<LaunchRuntimePayload, WorkspaceControlCode> {
        guard let executable = fields.executable, executable.hasPrefix("/") else {
            return .failure(.invalidRequest)
        }
        // Explicit selection only: a missing ID always means the base fence.
        // The policy's defaultProfile is a UI hint the host never consults.
        let resourceProfile: RuntimeResourceProfile?
        if let id = fields.resourceProfileID {
            guard let selected = resourcePolicy.profile(id: id, project: project) else {
                return .failure(.resourceProfileUnavailable)
            }
            resourceProfile = selected
        } else {
            resourceProfile = nil
        }
        let hook: HookHost?
        switch legacyLaunchHookSelection(fields.hook) {
        case .failure(let code):
            return .failure(code)
        case .success(let selected):
            hook = selected
        }
        guard let command = IsolatedCommand(
            executable: executable,
            arguments: fields.arguments ?? []
        ) else {
            return .failure(.invalidRequest)
        }
        switch workspaceLaunchIO(io: fields.io, rows: fields.rows, columns: fields.columns) {
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
        _ fields: WorkspaceControlRequestPayload.Launch
    ) -> Result<EnsureTerminalRuntimePayload, WorkspaceControlCode> {
        guard let executable = fields.executable, executable.hasPrefix("/"),
            let command = IsolatedCommand(
                executable: executable,
                arguments: fields.arguments ?? []
            )
        else {
            return .failure(.invalidRequest)
        }
        let hook: HookHost?
        switch legacyLaunchHookSelection(fields.hook) {
        case .failure(let code):
            return .failure(code)
        case .success(let selected):
            hook = selected
        }
        switch workspaceLaunchIO(io: fields.io, rows: fields.rows, columns: fields.columns) {
        case .success(let io):
            guard case .pseudoTerminal = io else {
                return .failure(.invalidRequest)
            }
            return .success(EnsureTerminalRuntimePayload(
                command: command,
                io: io,
                hook: hook,
                resourceProfileID: fields.resourceProfileID
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
        _ fields: WorkspaceControlRequestPayload.RuntimeRef
    ) -> Result<CancelRuntimePayload, WorkspaceControlCode> {
        guard let runtime = fields.runtime else {
            return .failure(.invalidRequest)
        }
        return .success(CancelRuntimePayload(runtime: runtime))
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
