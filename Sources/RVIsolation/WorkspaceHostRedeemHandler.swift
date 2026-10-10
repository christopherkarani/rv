#if os(macOS)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIPC

/// Host-side redemption kind. Mirrors the wire `"launchAgent"` /
/// `"launchCustom"` strings; the supervisor compares against the retained
/// intent target, never against definition names or executables.
enum HostRedemptionKind: String, Sendable, Equatable {
    case launchAgent
    case launchCustom
}

/// One authenticated redemption commit, verified against host identity.
///
/// Constructed only from a commit DTO that arrived over the authenticated
/// service channel (the bridge verifies the service peer before the handler
/// runs) and only when the DTO shape is exact: known kind, well-formed
/// digest, and definition fields present exactly for named launches.
/// Construction is still not authority: the supervisor re-verifies every
/// binding against its retained prepared operation and its live workspace
/// before the prepared→accepted transition.
struct HostRedemptionCommit: Sendable, Equatable {
    let authorizationID: UUID
    let workspace: WorkspaceSessionID
    let host: WorkspaceHostID
    let generation: WorkspaceHostGeneration
    let preparedID: PreparedLaunchID
    let intentDigest: WorkspaceLaunchIntentDigest
    let kind: HostRedemptionKind
    /// Required for `.launchAgent`, forbidden for `.launchCustom`.
    let definitionID: AgentDefinitionID?
    let definitionRevision: AgentDefinitionRevision?

    init(
        authorizationID: UUID,
        workspace: WorkspaceSessionID,
        host: WorkspaceHostID,
        generation: WorkspaceHostGeneration,
        preparedID: PreparedLaunchID,
        intentDigest: WorkspaceLaunchIntentDigest,
        kind: HostRedemptionKind,
        definitionID: AgentDefinitionID?,
        definitionRevision: AgentDefinitionRevision?
    ) {
        self.authorizationID = authorizationID
        self.workspace = workspace
        self.host = host
        self.generation = generation
        self.preparedID = preparedID
        self.intentDigest = intentDigest
        self.kind = kind
        self.definitionID = definitionID
        self.definitionRevision = definitionRevision
    }

    init?(request: HostRedeemCommitDTO) {
        guard let kind = HostRedemptionKind(rawValue: request.kind),
            Self.isLowerHex64(request.intentDigestHex)
        else {
            return nil
        }
        switch kind {
        case .launchAgent:
            guard let rawID = request.definitionID,
                let definitionID = AgentDefinitionID(validating: rawID),
                let revisionHex = request.revisionDigest,
                Self.isLowerHex64(revisionHex)
            else {
                return nil
            }
            self.definitionID = definitionID
            self.definitionRevision = AgentDefinitionRevision(digestHex: revisionHex)
        case .launchCustom:
            guard request.definitionID == nil, request.revisionDigest == nil else {
                return nil
            }
            self.definitionID = nil
            self.definitionRevision = nil
        }
        self.authorizationID = request.authorizationID
        self.workspace = WorkspaceSessionID(rawValue: request.workspaceSessionID)
        self.host = WorkspaceHostID(rawValue: request.hostID)
        self.generation = WorkspaceHostGeneration(rawValue: request.generation)
        self.preparedID = PreparedLaunchID(rawValue: request.preparedID)
        self.intentDigest = WorkspaceLaunchIntentDigest(sha256Hex: request.intentDigestHex)
        self.kind = kind
    }

    private static func isLowerHex64(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}

/// Fresh runtime identity established by one accepted redemption.
/// Identifiers for audit attribution only.
struct RedeemedIdentityLaunch: Sendable, Equatable {
    let runtime: RuntimeSessionID
    let instance: AgentInstanceID
}

/// Terminal outcome of one redemption attempt.
///
/// `accepted` reports whether the prepared→accepted transition committed
/// (the authorization is spent) or the commit was refused pre-accept (the
/// prepared operation is unspent by this refusal). A spent authorization
/// never dispatches again: replays return the recorded outcome.
enum HostRedemptionResult: Sendable, Equatable {
    case launched(runtime: RuntimeSessionID, instance: AgentInstanceID)
    case failed(accepted: Bool, error: WorkspaceSessionError)
}

/// Cwd re-verification for the spawn-commit critical section: the live
/// policy workspace must still resolve to the retained identity.
struct CwdCommitVerification: Sendable, Equatable {
    let policyWorkspacePath: String
    let expected: CwdIdentityStamp
}

/// Executable re-verification for the spawn-commit critical section:
/// the custom executable's live bytes must still hash to the digest
/// the operator authorized. Nil for named selections (weak-only, no
/// pinned digest to verify).
struct ExecutableCommitVerification: Sendable, Equatable {
    let executablePath: String
    let expectedSHA256: String
    /// Dispatch-captured regular-file size. Nil when dispatch could not
    /// measure one (missing or non-regular executable): verification
    /// then always refuses. Bounds the commit hash so a swapped-in huge
    /// file refuses after a stat instead of stalling the supervisor
    /// state lock hashing to EOF.
    let expectedByteCount: UInt64?
}

/// Regular-file size of a launch executable, or nil when the path is
/// missing, unstatted, or not a regular file (directory, fifo, socket,
/// device). Follows symlinks exactly like the exec path and the content
/// hash, so link swaps measure their new target. Any stat(2) failure
/// fails closed.
func measureExecutableSize(atPath path: String) -> UInt64? {
    var info = stat()
    guard stat(path, &info) == 0,
        (info.st_mode & S_IFMT) == S_IFREG,
        info.st_size >= 0
    else {
        return nil
    }
    return UInt64(info.st_size)
}

/// Measures a custom executable's content against the authorized digest.
/// Anything unreadable or unequal refuses: missing files, directories,
/// fifos, permission failures, size drift, and swapped bytes all fail
/// closed. The expected value compares case-insensitively (hex); a
/// malformed expectation can never match a measurement.
///
/// The size gate runs before the hash: the commit re-stats the path and
/// refuses on any non-regular shape or size drift, then hashes at most
/// `expectedByteCount` bytes, so the in-lock read is bounded by the
/// dispatch-captured size. Residual: bytes are verified at T and
/// executed by path at T+ε; a same-user swap inside that microsecond
/// window is undetected (closing it needs fd-based exec, future work).
func verifyExecutableContentDigest(
    path: String, expectedSHA256: String, expectedByteCount: UInt64?
) -> Bool {
    guard let expectedByteCount,
        measureExecutableSize(atPath: path) == expectedByteCount,
        let measured = RVFileDigest.sha256HexOfFile(atPath: path, maxBytes: expectedByteCount)
    else {
        return false
    }
    return measured == expectedSHA256.lowercased()
}

/// Host-side redemption RPC implementation (verify + accept + dispatch).
///
/// Pure function over the supervisor: answers `rv.host-redeem` commits from
/// rvd. The bridge authenticates the service peer before this runs; this
/// handler additionally requires the commit to name this exact host
/// incarnation and workspace, and the supervisor requires every remaining
/// binding to match its retained prepared operation. Refusals are coarse
/// machine-readable codes, never internal errors or paths.
enum WorkspaceHostRedeemHandler {
    /// Closed refusal/failure vocabulary. Anything else is never emitted.
    static let knownResponseErrors: Set<String> = [
        "unknown", "alreadyAccepted", "launchFailed",
    ]

    static func redeem(
        _ request: HostRedeemCommitDTO,
        supervisor: WorkspaceSessionSupervisor,
        sessionStore: RuntimeSessionStore,
        admission: RuntimeAdmissionConfiguration,
        host: WorkspaceHostID,
        generation: WorkspaceHostGeneration,
        audit: (@Sendable (WorkspaceHostRedemptionAuditEvent) -> Void)? = nil
    ) -> HostRedeemResponseDTO {
        func refuse(
            _ code: String, commit: HostRedemptionCommit? = nil, outcome: String
        ) -> HostRedeemResponseDTO {
            // Unvalidated DTO strings never reach audit: a malformed commit
            // (up to the 1MB transport cap) would otherwise plant unbounded
            // text in the log. Validated commits carry bounded values only
            // (64-hex digest, closed kind vocabulary).
            let digest = commit?.intentDigest.sha256Hex ?? ""
            let kind = commit?.kind.rawValue ?? "malformed"
            audit?(WorkspaceHostRedemptionAuditEvent(
                kind: .commitRefused,
                authorizationID: commit?.authorizationID ?? request.authorizationID,
                preparedID: commit?.preparedID.rawValue ?? request.preparedID,
                workspace: request.workspaceSessionID,
                host: request.hostID,
                generation: request.generation,
                intentDigestHex: digest,
                operationKind: kind,
                runtime: nil,
                instance: nil,
                wall: Date(),
                outcome: outcome))
            return HostRedeemResponseDTO(accepted: false, error: code)
        }
        guard let commit = HostRedemptionCommit(request: request) else {
            return refuse("unknown", outcome: "malformed commit")
        }
        guard commit.host == host,
            commit.generation == generation,
            commit.workspace == supervisor.id
        else {
            return refuse("unknown", commit: commit, outcome: "not this host incarnation")
        }
        switch supervisor.redeemPreparedLaunch(
            commit: commit,
            sessionStore: sessionStore,
            admission: admission,
            runningLimit: WorkspaceControlLimits.maxRuntimes
        ) {
        case .launched(let runtime, let instance):
            audit?(WorkspaceHostRedemptionAuditEvent(
                kind: .redemptionLaunched,
                authorizationID: commit.authorizationID,
                preparedID: commit.preparedID.rawValue,
                workspace: request.workspaceSessionID,
                host: request.hostID,
                generation: request.generation,
                intentDigestHex: request.intentDigestHex,
                operationKind: request.kind,
                runtime: runtime.rawValue,
                instance: instance.rawValue,
                wall: Date(),
                outcome: "launched"))
            return HostRedeemResponseDTO(
                accepted: true,
                runtimeSessionID: runtime.rawValue,
                agentInstanceID: instance.rawValue)
        case .failed(let accepted, let error):
            if accepted, case .redemptionAlreadyAccepted = error {
                audit?(WorkspaceHostRedemptionAuditEvent(
                    kind: .duplicateCommit,
                    authorizationID: commit.authorizationID,
                    preparedID: commit.preparedID.rawValue,
                    workspace: request.workspaceSessionID,
                    host: request.hostID,
                    generation: request.generation,
                    intentDigestHex: request.intentDigestHex,
                    operationKind: request.kind,
                    runtime: nil,
                    instance: nil,
                    wall: Date(),
                    outcome: "already accepted"))
                return HostRedeemResponseDTO(accepted: true, error: "alreadyAccepted")
            }
            if accepted {
                audit?(WorkspaceHostRedemptionAuditEvent(
                    kind: .redemptionFailed,
                    authorizationID: commit.authorizationID,
                    preparedID: commit.preparedID.rawValue,
                    workspace: request.workspaceSessionID,
                    host: request.hostID,
                    generation: request.generation,
                    intentDigestHex: request.intentDigestHex,
                    operationKind: request.kind,
                    runtime: nil,
                    instance: nil,
                    wall: Date(),
                    outcome: "launch failed"))
                return HostRedeemResponseDTO(accepted: true, error: "launchFailed")
            }
            return refuse("unknown", commit: commit, outcome: "refused pre-accept")
        }
    }
}

/// Host-side redemption audit event. Carries identities, digests and
/// outcomes only — never argv, secret environment, capabilities, or paths
/// beyond the already-reviewed working directory.
struct WorkspaceHostRedemptionAuditEvent: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case commitRefused
        case duplicateCommit
        case redemptionLaunched
        case redemptionFailed
    }

    let kind: Kind
    let authorizationID: UUID
    let preparedID: UUID
    let workspace: UUID
    let host: UUID
    let generation: UUID
    let intentDigestHex: String
    let operationKind: String
    let runtime: UUID?
    let instance: UUID?
    let wall: Date
    let outcome: String
}
#endif
