import Foundation
import RVDomain
import RVEngine
import RVIPC
import RVPolicy

/// Pending list/watch/resolve and rule preview/save. Plant, consume, and
/// rule-pin polarity live here so handshake and evaluate stay off this wait.
package actor ApprovalRuntime {
    private let pendingApprovals: (any PendingApprovalCoordinating)?
    private let allowOnce: AllowOnceStore
    private let clock: @Sendable () -> Date
    private let peek: @Sendable (ShellCommand, WorkingDirectory?, Date) async -> EvaluationResult
    private var pendingGeneration: UInt64 = 0
    private var pendingSetFingerprint: [String] = []

    package init(
        pendingApprovals: (any PendingApprovalCoordinating)?,
        allowOnce: AllowOnceStore,
        clock: @escaping @Sendable () -> Date,
        peek: @escaping @Sendable (ShellCommand, WorkingDirectory?, Date) async -> EvaluationResult
    ) {
        self.pendingApprovals = pendingApprovals
        self.allowOnce = allowOnce
        self.clock = clock
        self.peek = peek
    }

    package func list() async -> IPCResult {
        do {
            return .pendingList(try await makePendingListReply())
        } catch {
            return .error(PendingListProjection.ipcError(from: error))
        }
    }

    package func watch(afterGeneration: UInt64) async -> IPCResult {
        do {
            let reply = try await makePendingListReply()
            if afterGeneration == reply.generation {
                return .pendingWatch(PendingListReply(generation: reply.generation, items: []))
            }
            return .pendingWatch(reply)
        } catch {
            return .error(PendingListProjection.ipcError(from: error))
        }
    }

    package func resolve(_ params: PendingResolveParams) async -> IPCResult {
        guard let pendingApprovals else {
            return .error(PendingListProjection.coordinatorUnavailable)
        }
        switch params.decision {
        case .allowOnce:
            return await resolveAllowOnce(params, store: pendingApprovals)
        case .deny:
            return await resolvePendingDecision(
                params,
                decision: .deny,
                store: pendingApprovals
            )
        }
    }

    package func previewRule(_ params: RulePreviewParams) async -> IPCResult {
        guard let pendingApprovals else {
            return .error(PendingListProjection.coordinatorUnavailable)
        }
        do {
            let record = try await pendingApprovals.load(id: params.id, now: clock())
            let preview = RulePinning.preview(
                record: record,
                polarity: pinnedPolarity(params.polarity)
            )
            return .rulePreview(
                RulePreviewReply(
                    sentence: preview.sentence,
                    draft: preview.draft,
                    allowedToSave: preview.allowedToSave
                )
            )
        } catch {
            return .error(PendingListProjection.ipcError(from: error))
        }
    }

    package func saveRule(_ params: RuleSaveParams) async -> IPCResult {
        guard let pendingApprovals else {
            return .error(PendingListProjection.coordinatorUnavailable)
        }
        let polarity = pinnedPolarity(params.polarity)
        do {
            let now = clock()
            let record = try await pendingApprovals.load(id: params.id, now: now)
            let commandText = record.action.supportingCommand?.rawValue ?? ""
            let outcome = try RulePinStore(baseDirectory: allowOnce.baseDirectory).save(
                record: record,
                polarity: polarity,
                draft: params.draft,
                now: now,
                matchingView: Normalize.matchingView(of: commandText)
            )
            let decision: ApprovalDecision = polarity == .allow ? .createRule : .deny
            do {
                let resolved = try await pendingApprovals.resolve(
                    id: record.id,
                    decision: decision,
                    fingerprint: record.fingerprint,
                    identity: record.identity,
                    now: now
                )
                let terminal: Bool
                switch resolved.state {
                case .awaitingHuman:
                    terminal = false
                case .resolved, .consumed, .expired, .canceled, .timedOut:
                    terminal = true
                }
                return .ruleSave(RuleSaveReply(ruleID: outcome.ruleID, waitResolved: terminal))
            } catch let error as PendingApprovalError {
                switch error {
                case .alreadyResolved, .alreadyConsumed, .expired, .canceled, .timedOut:
                    return .ruleSave(RuleSaveReply(ruleID: outcome.ruleID, waitResolved: true))
                case .notFound, .invalidRequest, .duplicateID, .fingerprintMismatch, .identityMismatch,
                    .continuationMismatch, .notResolved, .encodeFailed, .lockFailed:
                    return .error(PendingListProjection.ipcError(from: error))
                }
            }
        } catch let error as RulePinError {
            switch error {
            case .draftMismatch:
                return .error(.ruleDraftMismatch)
            case .hardStop:
                return .error(.ruleHardStop)
            case .missingMatchingView:
                return .error(.rulePinRequiresMatchingView)
            }
        } catch {
            return .error(PendingListProjection.ipcError(from: error))
        }
    }

    private func pinnedPolarity(_ wire: RulePolarity) -> PinnedRulePolarity {
        switch wire {
        case .allow:
            return .allow
        case .block:
            return .block
        }
    }

    private func resolveAllowOnce(
        _ params: PendingResolveParams,
        store: any PendingApprovalCoordinating
    ) async -> IPCResult {
        let now = clock()
        let record: PendingApproval
        do {
            record = try await store.load(id: params.id, now: now)
        } catch {
            return .error(PendingListProjection.ipcError(from: error))
        }
        switch record.state {
        case .awaitingHuman:
            break
        case .resolved, .consumed, .expired, .canceled, .timedOut:
            return .error(.pendingAlreadyTerminal)
        }
        guard record.fingerprint == params.fingerprint, record.identity == params.identity else {
            return .error(
                PendingListProjection.ipcError(
                    from: record.fingerprint == params.fingerprint
                        ? PendingApprovalError.identityMismatch
                        : PendingApprovalError.fingerprintMismatch
                )
            )
        }
        let cwd = record.action.scope.workingDirectory
        guard let command = record.action.supportingCommand else {
            return .error(.pendingAllowOnceNotUnlockable)
        }
        let peeked = await peek(command, cwd, now)
        switch PendingAllowOncePlanner.plan(peek: peeked, cwd: cwd) {
        case .refuse:
            return .error(.pendingAllowOnceNotUnlockable)
        case .resolveWithoutGrant:
            return await resolvePendingDecision(
                params,
                decision: .allowOnce,
                store: store,
                now: now
            )
        case .plant(let matchingView, let grantCwd):
            let resolved = await resolvePendingDecision(
                params,
                decision: .allowOnce,
                store: store,
                now: now
            )
            guard case .pendingResolve = resolved else {
                return resolved
            }
            do {
                try await allowOnce.insertGranted(
                    matchingView: matchingView,
                    cwd: grantCwd,
                    now: now
                )
            } catch {
                _ = try? await store.consume(
                    id: params.id,
                    fingerprint: params.fingerprint,
                    identity: params.identity,
                    now: now
                )
                return .error(.pendingAllowOnceNotUnlockable)
            }
            do {
                _ = try await store.consume(
                    id: params.id,
                    fingerprint: params.fingerprint,
                    identity: params.identity,
                    now: now
                )
            } catch {
                return .error(PendingListProjection.ipcError(from: error))
            }
            return resolved
        }
    }

    private func resolvePendingDecision(
        _ params: PendingResolveParams,
        decision: ApprovalDecision,
        store: any PendingApprovalCoordinating,
        now: Date? = nil
    ) async -> IPCResult {
        do {
            let resolved = try await store.resolve(
                id: params.id,
                decision: decision,
                fingerprint: params.fingerprint,
                identity: params.identity,
                now: now ?? clock()
            )
            return .pendingResolve(
                PendingResolveReply(id: resolved.id, terminal: isTerminal(resolved.state))
            )
        } catch {
            return .error(PendingListProjection.ipcError(from: error))
        }
    }

    private func isTerminal(_ state: PendingApprovalState) -> Bool {
        switch state {
        case .awaitingHuman:
            return false
        case .resolved, .consumed, .expired, .canceled, .timedOut:
            return true
        }
    }

    private func makePendingListReply() async throws -> PendingListReply {
        guard let pendingApprovals else {
            throw PendingListProjection.coordinatorUnavailable
        }
        let records = try await pendingApprovals.list(now: clock())
        let fingerprint = PendingListProjection.fingerprint(records)
        if fingerprint != pendingSetFingerprint {
            pendingGeneration += 1
            pendingSetFingerprint = fingerprint
        }
        return PendingListReply(
            generation: pendingGeneration,
            items: PendingListProjection.items(from: records)
        )
    }
}
