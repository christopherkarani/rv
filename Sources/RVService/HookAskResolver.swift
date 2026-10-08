import Foundation
import RVDomain
import RVEngine
import RVIPC
import RVPolicy

/// Owner-authorized resolution of hook-ask waits. Step 8B.
///
/// The daemon reaches this core only through an authorized transport:
/// an operator-UI ceremony completion (genuine UI peer, bound challenge)
/// or an unlock-code redemption (single-use code plus device-owner
/// check). Generic IPC `pendingResolve` stays denied: knowing a row ID
/// is not authority.
///
/// The core is host-universal: every coding host resolves through the
/// same peek → plan → CAS-resolve → plant/consume sequence. It never
/// touches `AgentInstance` grants and never admits Secrets/MCP authority
/// (F3): the only effect is one exact-command allow-once grant plus the
/// wait's terminal transition.
///
/// Step 8B.1: the plant lands in the service-held memory table (sole
/// authority); the file receives a display projection only.
enum HookAskResolver {
    static func resolve(
        params: PendingResolveParams,
        reviewedAction: (command: ShellCommand?, cwd: WorkingDirectory?)?,
        pending: (any PendingApprovalCoordinating)?,
        grants: EphemeralAllowOnceTable,
        projection: AllowOnceStore,
        peek: @escaping @Sendable (ShellCommand, WorkingDirectory?, Date) async -> EvaluationResult,
        now: Date
    ) async -> Result<PendingResolveReply, IPCError> {
        guard let pending else {
            return .failure(.pendingCoordinatorUnavailable)
        }
        switch params.decision {
        case .allowOnce:
            return await resolveAllowOnce(
                params,
                reviewedAction: reviewedAction,
                store: pending,
                grants: grants,
                projection: projection,
                peek: peek,
                now: now
            )
        case .deny:
            return await resolveDecision(
                params,
                decision: .deny,
                store: pending,
                now: now
            )
        }
    }

    private static func resolveAllowOnce(
        _ params: PendingResolveParams,
        reviewedAction: (command: ShellCommand?, cwd: WorkingDirectory?)?,
        store: any PendingApprovalCoordinating,
        grants: EphemeralAllowOnceTable,
        projection: AllowOnceStore,
        peek: @escaping @Sendable (ShellCommand, WorkingDirectory?, Date) async -> EvaluationResult,
        now: Date
    ) async -> Result<PendingResolveReply, IPCError> {
        let record: PendingApproval
        do {
            record = try await store.load(id: params.id, now: now)
        } catch {
            return .failure(PendingListProjection.ipcError(from: error))
        }
        switch record.state {
        case .awaitingHuman:
            break
        case .resolved, .consumed, .expired, .canceled, .timedOut:
            return .failure(.pendingAlreadyTerminal)
        }
        guard record.fingerprint == params.fingerprint, record.identity == params.identity else {
            return .failure(
                PendingListProjection.ipcError(
                    from: record.fingerprint == params.fingerprint
                        ? PendingApprovalError.identityMismatch
                        : PendingApprovalError.fingerprintMismatch
                )
            )
        }
        // Exact-row bind: the stored fingerprint string is file text the
        // same-user attacker controls, so equality above cannot prove the
        // re-loaded action is the one the human reviewed. Compare the
        // re-loaded plant inputs against the ceremony's in-memory
        // snapshot; any drift fails closed. The plant below derives from
        // this same loaded record, so no window remains.
        guard let reviewedAction,
            record.action.supportingCommand == reviewedAction.command,
            record.action.scope.workingDirectory == reviewedAction.cwd
        else {
            return .failure(
                PendingListProjection.ipcError(from: PendingApprovalError.fingerprintMismatch))
        }
        let cwd = record.action.scope.workingDirectory
        guard let command = record.action.supportingCommand else {
            return .failure(.pendingAllowOnceNotUnlockable)
        }
        let peeked = await peek(command, cwd, now)
        switch PendingAllowOncePlanner.plan(peek: peeked, cwd: cwd) {
        case .refuse:
            return .failure(.pendingAllowOnceNotUnlockable)
        case .resolveWithoutGrant:
            return await resolveDecision(
                params,
                decision: .allowOnce,
                store: store,
                now: now
            )
        case .plant(let matchingView, let grantCwd):
            // Resolve-first CAS: exactly one resolver wins, so exactly one
            // grant exists for the wait. The row ends at `.resolved`; the
            // grant itself is the single-use token the retry spends.
            // (Step 8: name-only `consume` delivers denies only.)
            let resolved = await resolveDecision(
                params,
                decision: .allowOnce,
                store: store,
                now: now
            )
            guard case .success = resolved else {
                return resolved
            }
            // Step 8B.1: plant into service-held memory (sole authority),
            // with a best-effort display projection to the file. The plant
            // is keyed by ceremony: one pending row plants at most once per
            // epoch (the CAS above already guarantees one resolve winner).
            // M-07: the exact retained command binds the hidden payload, so
            // the grant authorizes this payload only. B1: it also binds the
            // erased invocation prefix, so the grant authorizes this exact
            // wrapper/assignment/argv0 spelling only.
            let segments = Normalize.maskedSegments(of: command)
            let prefix = Normalize.invocationPrefix(of: command)
            switch await grants.plant(
                matchingView: matchingView,
                cwd: grantCwd,
                codeHash: "pending:\(params.id.rawValue)",
                pendingID: params.id.rawValue,
                now: now,
                maskedSegments: segments,
                invocationPrefix: prefix
            ) {
            case .planted:
                await projection.project(
                    lifecycle: .granted,
                    matchingView: matchingView,
                    cwd: grantCwd,
                    codeHash: "pending:\(params.id.rawValue)",
                    now: now,
                    maskedSegments: segments,
                    invocationPrefix: prefix,
                    invocationDisplay: Normalize.invocationDisplay(of: command)
                )
                return resolved
            case .alreadyRedeemed, .refused:
                // The row stays resolved-without-grant: inert, and the next
                // consult mints a fresh wait (dedupe matches awaiting rows
                // only), so the human can approve again.
                return .failure(.pendingAllowOnceNotUnlockable)
            }
        }
    }

    private static func resolveDecision(
        _ params: PendingResolveParams,
        decision: ApprovalDecision,
        store: any PendingApprovalCoordinating,
        now: Date
    ) async -> Result<PendingResolveReply, IPCError> {
        do {
            let resolved = try await store.resolve(
                id: params.id,
                decision: decision,
                fingerprint: params.fingerprint,
                identity: params.identity,
                now: now
            )
            return .success(
                PendingResolveReply(id: resolved.id, terminal: isTerminal(resolved.state))
            )
        } catch {
            return .failure(PendingListProjection.ipcError(from: error))
        }
    }

    private static func isTerminal(_ state: PendingApprovalState) -> Bool {
        switch state {
        case .awaitingHuman:
            return false
        case .resolved, .consumed, .expired, .canceled, .timedOut:
            return true
        }
    }
}
