#if os(macOS)
import Foundation
import RVDomain
import RVIPC
import RVPolicy

/// Host-side prepare-only RPC implementation (resolve + prepare + describe).
///
/// Pure function over the supervisor: answers `rv.host-prepare` requests from
/// rvd. It never dispatches, spawns, or launches — `prepareIdentityLaunch`
/// only retains; the retained operation stays unreachable behind the host's
/// deny-all authorization. Refusals are coarse machine-readable codes, never
/// internal errors or paths.
///
/// The prepared working directory is always the host's resolved workspace
/// (Step 2 semantics); proposals carry no cwd, so none can be smuggled.
enum WorkspaceHostPrepareHandler {
    static func prepare(
        _ request: HostPrepareRequestDTO,
        supervisor: WorkspaceSessionSupervisor,
        definitions: AgentDefinitionSet,
        host: WorkspaceHostID,
        generation: WorkspaceHostGeneration,
        project: String
    ) -> HostPrepareResponseDTO {
        func refuse(_ code: String) -> HostPrepareResponseDTO {
            HostPrepareResponseDTO(description: nil, error: code)
        }
        guard supervisor.snapshot.phase.acceptsRuntime else {
            return refuse("notAccepting")
        }
        let selected: Result<ResolvedAgentLaunch, AgentLaunchSelectionError>
        switch request.kind {
        case "named":
            guard request.executable == nil, request.expectedDigest == nil,
                let raw = request.definitionID,
                let id = AgentDefinitionID(validating: raw)
            else {
                return refuse("invalidRequest")
            }
            selected = AgentLaunchSelection.resolveNamed(
                id: id, definitions: definitions, project: project
            )
        case "custom":
            guard request.definitionID == nil, let executable = request.executable,
                let digest = request.expectedDigest
            else {
                return refuse("invalidRequest")
            }
            selected = AgentLaunchSelection.resolveCustom(
                executable: executable, expectedContentDigestSHA256: digest
            )
        default:
            return refuse("invalidRequest")
        }
        let selection: ResolvedAgentLaunch
        switch selected {
        case .failure(let error):
            return refuse(selectionRefusal(error))
        case .success(let resolved):
            selection = resolved
        }
        let io: IsolatedIO
        switch request.io {
        case .discard:
            guard case .success(let mapped) = workspaceLaunchIO(io: nil, rows: nil, columns: nil) else {
                return refuse("invalidRequest")
            }
            io = mapped
        case .pseudoTerminal(let rows, let columns):
            guard case .success(let mapped) = workspaceLaunchIO(
                io: "terminal", rows: rows, columns: columns
            ) else {
                return refuse("invalidRequest")
            }
            io = mapped
        }
        let prepared: PreparedWorkspaceLaunch
        switch supervisor.prepareIdentityLaunch(
            selection: selection, arguments: request.arguments, io: io,
            host: host, generation: generation, requestID: request.requestID
        ) {
        case .failure:
            return refuse("preparationFailed")
        case .success(let retained):
            prepared = retained
        }
        guard let description = supervisor.describePreparedLaunch(prepared.binding.preparedLaunchID) else {
            return refuse("preparationFailed")
        }
        return HostPrepareResponseDTO(description: encode(description), error: nil)
    }

    private static func selectionRefusal(_ error: AgentLaunchSelectionError) -> String {
        switch error {
        case .unknownDefinition: return "unknownDefinition"
        case .invalidDefinition: return "invalidDefinition"
        case .projectNotEligible: return "projectNotEligible"
        case .executableUnavailable: return "executableUnavailable"
        case .invalidExecutable: return "invalidExecutable"
        case .unsupportedExecutableRequirement: return "unsupportedExecutable"
        case .credentialIntegrationDeferred: return "credentialDeferred"
        case .invalidCustomDigest: return "invalidDigest"
        }
    }

    private static func encode(_ description: PreparedLaunchDescription) -> HostPreparedDescriptionDTO {
        let summary = description.intent.auditSummary
        let io: UIIODTO
        switch summary.io {
        case .discard:
            io = .discard
        case .pseudoTerminal(let rows, let columns):
            io = .pseudoTerminal(rows: rows, columns: columns)
        }
        let environmentPolicy: String
        switch summary.environment {
        case .containedProjectionV1:
            environmentPolicy = "containedProjectionV1"
        }
        return HostPreparedDescriptionDTO(
            workspaceSessionID: description.binding.workspace.rawValue,
            hostID: description.binding.host.rawValue,
            generation: description.binding.generation.rawValue,
            preparedID: description.binding.preparedLaunchID.rawValue,
            requestID: description.requestID,
            target: summary.kind.rawValue,
            definitionID: summary.definitionID,
            revisionDigest: summary.definitionRevisionDigest,
            executable: summary.executable,
            expectedDigest: summary.expectedContentDigestSHA256,
            workingDirectory: summary.workingDirectory,
            arguments: summary.arguments,
            io: io,
            environmentPolicy: environmentPolicy,
            intentDigestHex: description.intentDigest.sha256Hex,
            environmentDigestHex: description.environmentDigestHex,
            preparedAt: description.preparedAt,
            expiresAt: description.expiresAt)
    }
}
#endif
