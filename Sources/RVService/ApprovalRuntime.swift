import Foundation
import RVDomain
import RVIPC
import RVPolicy

/// Pending list/watch/resolve and rule preview/save. Owned by `ServiceRuntime`.
/// Watch generation is isolated here. Allow-once peek is `LiveEvaluateWorld.peek`
/// with the compile set loaded at peek time so pack enable cannot leave a stale session.
actor ApprovalRuntime {
    private var pendingGeneration: UInt64 = 0
    private var pendingSetFingerprint: [String] = []
    private let allowOnce: AllowOnceStore
    private let clock: @Sendable () -> Date
    private let pendingApprovals: (any PendingApprovalCoordinating)?

    init(
        allowOnce: AllowOnceStore,
        clock: @escaping @Sendable () -> Date,
        pendingApprovals: (any PendingApprovalCoordinating)?
    ) {
        self.allowOnce = allowOnce
        self.clock = clock
        self.pendingApprovals = pendingApprovals
    }

    /// Frozen-clock peek. `gated` runs at peek time — do not pass a `GatedEvaluate`
    /// captured at `ApprovalRuntime` init or at `dispatch` entry, or a later
    /// `setPackEnabled` rebuild is invisible to allow-once.
    nonisolated static func livePeek(
        home: HomeDirectory?,
        store: AllowOnceStore,
        gated: @escaping @Sendable () async -> GatedEvaluate
    ) -> @Sendable (ShellCommand, WorkingDirectory?, Date) async -> EvaluationResult {
        { command, cwd, now in
            await LiveEvaluateWorld(
                home: home,
                store: store,
                gated: await gated(),
                clock: { now }
            ).peek(command: command, cwd: cwd)
        }
    }

    func pendingListResult() async -> Result<PendingListReply, IPCError> {
        do {
            return .success(try await makePendingListReply())
        } catch {
            return .failure(PendingListProjection.ipcError(from: error))
        }
    }

    func pendingWatchResult(afterGeneration: UInt64) async -> Result<PendingWatchReply, IPCError> {
        do {
            let reply = try await makePendingListReply()
            if afterGeneration == reply.generation {
                return .success(PendingWatchReply(generation: reply.generation, items: []))
            }
            return .success(reply)
        } catch {
            return .failure(PendingListProjection.ipcError(from: error))
        }
    }

    func rulePreviewResult(_ params: RulePreviewParams) async -> Result<RulePreviewReply, IPCError> {
        guard let pendingApprovals else {
            return .failure(PendingListProjection.coordinatorUnavailable)
        }
        do {
            let record = try await pendingApprovals.load(id: params.id, now: clock())
            let preview = RulePinning.preview(
                record: record,
                polarity: pinnedPolarity(params.polarity)
            )
            return .success(
                RulePreviewReply(
                    sentence: preview.sentence,
                    draft: preview.draft,
                    allowedToSave: preview.allowedToSave
                )
            )
        } catch {
            return .failure(PendingListProjection.ipcError(from: error))
        }
    }

    func ruleSaveResult(_ params: RuleSaveParams) async -> Result<RuleSaveReply, IPCError> {
        // No authenticated authoritative-host channel or principal-bound grant
        // store is installed yet. Saving first would leave persistent authority
        // even if later authentication or live validation failed.
        .failure(.authorizationDenied)
    }

    func pendingResolveResult(
        _ params: PendingResolveParams,
        peek: @escaping @Sendable (ShellCommand, WorkingDirectory?, Date) async -> EvaluationResult
    ) async -> Result<PendingResolveReply, IPCError> {
        // The old name-bound resolver planted a command/cwd grant. Neither
        // knowing a row ID nor authenticating a CLI can authorize that grant.
        .failure(.authorizationDenied)
    }

    private func pinnedPolarity(_ wire: RulePolarity) -> PinnedRulePolarity {
        switch wire {
        case .allow:
            return .allow
        case .block:
            return .block
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
