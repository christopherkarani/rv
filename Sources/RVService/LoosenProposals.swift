import Foundation
import RVDomain
import RVEngine
import RVHistory
import RVIPC
import RVPacks
import RVPolicy

/// Applies one approved loosen to the owner's config. rvd calls it only
/// inside `LoosenProposalService.decide`, after the owner check passed and
/// under the proposal store's lock. Tests swap in a recorder; production
/// uses `live`.
package struct LoosenApplier: Sendable {
    /// Why `change` cannot be applied on this machine (unknown pack, bad
    /// rule id), or nil. Checked when it is filed and again before applying.
    package var problem: @Sendable (PolicyLoosen) -> String?
    /// Writes the change. `authorization` is bound to
    /// `ConfigChangeAudit.authorization` for the write-ahead audit event.
    package var apply: @Sendable (PolicyLoosen, _ authorization: String) throws -> Void

    package init(
        problem: @escaping @Sendable (PolicyLoosen) -> String?,
        apply: @escaping @Sendable (PolicyLoosen, String) throws -> Void
    ) {
        self.problem = problem
        self.apply = apply
    }

    /// The real stores under `home`'s rv config directory.
    package static func live(home: HomeDirectory) -> LoosenApplier {
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        return LoosenApplier(
            problem: { change in
                switch change {
                case .allowRule(let rule, _):
                    return parseAllowlistRuleID(rule) == nil ? "\(rule) is not a rule id (pack:rule)" : nil
                case .packOff(let pack):
                    guard let index = try? PackRegistry.loadIndex() else { return "rv cannot read its pack index" }
                    // The names `rv packs disable` takes: a pack id, a category or a preset.
                    return PacksFacade.knownSelections(index: index).contains(pack)
                        ? nil : "\(pack) is not a pack, category or preset"
                case .allowCommand, .safetyNormal:
                    return nil
                }
            },
            apply: { change, authorization in
                try ConfigChangeAudit.$authorization.withValue(authorization) {
                    switch change {
                    case .allowRule(let rule, let reason):
                        guard let ruleID = parseAllowlistRuleID(rule) else {
                            throw LoosenProposalError.invalid("\(rule) is not a rule id")
                        }
                        try AllowlistStore(baseDirectory: configDirectory).pin(
                            AllowlistEntry(selector: .rule(ruleID), reason: reason, addedAt: Date()))
                    case .allowCommand(let command, let reason):
                        let shell = ShellCommand(rawValue: command)
                        try AllowlistStore(baseDirectory: configDirectory).pin(
                            AllowlistEntry(
                                selector: .exactCommand(EvaluationWorld.matchingView(of: shell)),
                                reason: reason,
                                addedAt: Date(),
                                maskedPayloadDigest: maskedPayloadContentDigest(Normalize.maskedSegments(of: shell)),
                                invocationDigest: maskedPayloadContentDigest(Normalize.invocationPrefix(of: shell))))
                    case .safetyNormal:
                        try SafetyStore(configDirectory: configDirectory).saveMachine(.normal)
                    case .packOff(let pack):
                        _ = try PacksFacade.disable(home: home, ids: [pack])
                    }
                }
            })
    }
}

/// rvd's side of loosen proposals (F2). Filing, listing and declining
/// loosen nothing and need only a kernel-attested peer. Approving needs
/// the device owner at rvd's own check (`OwnerPresence`), with a prompt
/// rvd builds from the stored row, and applies only the row whose content
/// still hashes to what the caller showed the owner.
///
/// No caller can apply a loosen any other way: there is no method that
/// takes a change and applies it, and `decide` applies only a stored row.
package struct LoosenProposalService: Sendable {
    package let store: LoosenProposalStore?
    package let applier: LoosenApplier?
    package let publish: @Sendable (LiveEventPayload, Date) -> Void

    package init(
        store: LoosenProposalStore?, applier: LoosenApplier?,
        publish: @escaping @Sendable (LiveEventPayload, Date) -> Void
    ) {
        self.store = store
        self.applier = applier
        self.publish = publish
    }

    // MARK: - Methods

    package func propose(_ params: ProposeLoosenParams, now: Date) async -> ProposeLoosenReply {
        guard let store, let applier else { return ProposeLoosenReply(outcome: .unavailable) }
        for label in [params.from, params.cwd] {
            if let label, label.utf8.count > ProposeLoosenParams.maxLabelBytes {
                return ProposeLoosenReply(outcome: .invalid, problem: "a label is longer than \(ProposeLoosenParams.maxLabelBytes) bytes")
            }
        }
        if let problem = params.change.problem ?? applier.problem(params.change) {
            return ProposeLoosenReply(outcome: .invalid, problem: problem)
        }
        let filed = await Self.offActor { () throws(LoosenProposalError) in
            try store.propose(params.change, from: params.from, cwd: params.cwd, now: now)
        }
        switch filed {
        case .success(let result):
            if result.created { announce(result.proposal, at: now) }
            return ProposeLoosenReply(outcome: .filed, proposal: Self.item(result.proposal), created: result.created)
        case .failure(.invalid(let problem)):
            return ProposeLoosenReply(outcome: .invalid, problem: problem)
        case .failure(.full):
            return ProposeLoosenReply(outcome: .full)
        case .failure:
            return ProposeLoosenReply(outcome: .unavailable)
        }
    }

    package func list(_ params: ListProposalsParams, now: Date) async -> ListProposalsReply {
        guard let store else { return ListProposalsReply(proposals: [], readable: false) }
        let listed = await Self.offActor { () throws(LoosenProposalError) in try store.list(now: now) }
        guard case .success(let result) = listed else { return ListProposalsReply(proposals: [], readable: false) }
        for expired in result.expiredNow { announce(expired, at: now) }
        let rows = params.includeDecided ? result.all : result.all.filter { $0.status == .pending }
        return ListProposalsReply(proposals: rows.map(Self.item))
    }

    /// Approve or decline. `confirm` is rvd's owner check
    /// (`OwnerPresence.confirm` plus its audit record): true only when the
    /// owner approved `prompt` and the approval was recorded.
    package func decide(
        _ params: DecideProposalParams,
        now: @escaping @Sendable () -> Date,
        confirm: @Sendable (_ prompt: String) async -> (approved: Bool, reply: ConfirmOwnerActionReply)
    ) async -> DecideProposalReply {
        guard let store, let applier else { return DecideProposalReply(outcome: .unavailable) }
        // What the owner is asked about comes from the stored row, checked
        // against the hash the caller showed, before any prompt.
        let shown = await Self.offActor { () throws(LoosenProposalError) -> LoosenProposal in
            let listed = try store.list(now: now())
            return try LoosenProposalLedger.pending(params.id, shownHash: params.contentHash, in: listed.all)
        }
        let record: LoosenProposal
        switch shown {
        case .success(let found): record = found
        case .failure(let error): return await refusal(error, id: params.id, store: store, now: now())
        }
        switch params.decision {
        case .reject:
            let declined = await Self.offActor { () throws(LoosenProposalError) -> LoosenProposal in
                try store.update { records throws(LoosenProposalError) in
                    let result = try LoosenProposalLedger.decide(
                        params.id, shownHash: params.contentHash, to: .rejected, declineReason: params.reason,
                        records: records, now: now())
                    return (result.proposal, result.records)
                }
            }
            switch declined {
            case .success(let row):
                announce(row, at: now())
                return DecideProposalReply(outcome: .rejected, proposal: Self.item(row))
            case .failure(let error):
                return await refusal(error, id: params.id, store: store, now: now())
            }
        case .approve:
            // Never ask the owner about a change rvd could not apply.
            if let problem = applier.problem(record.change) {
                return DecideProposalReply(outcome: .invalid, proposal: Self.item(record), problem: problem)
            }
            let owner = await confirm(Self.prompt(for: record))
            guard owner.approved else {
                return DecideProposalReply(outcome: .ownerRefused, proposal: Self.item(record), owner: owner.reply)
            }
            let authorization = Self.authorization(presence: owner.reply.presence, id: record.id)
            // Compare-and-set under the store lock, then apply, then save:
            // a row that changed while the owner read the prompt is refused,
            // and a failed apply leaves the row pending.
            let applied = await Self.offActor { () throws(LoosenProposalError) -> LoosenProposal in
                try store.update { records throws(LoosenProposalError) in
                    let result = try LoosenProposalLedger.decide(
                        params.id, shownHash: params.contentHash, to: .approved, records: records, now: now())
                    do {
                        try applier.apply(result.proposal.change, authorization)
                    } catch {
                        throw .applyFailed(Self.applyProblem(error))
                    }
                    return (result.proposal, result.records)
                }
            }
            switch applied {
            case .success(let row):
                announce(row, at: now())
                return DecideProposalReply(outcome: .approved, proposal: Self.item(row), owner: owner.reply)
            case .failure(.applyFailed(let problem)):
                return DecideProposalReply(
                    outcome: .applyFailed, proposal: Self.item(record), owner: owner.reply, problem: problem)
            case .failure(let error):
                return await refusal(error, id: params.id, store: store, now: now())
            }
        }
    }

    // MARK: - Pure helpers

    /// rvd's prompt for approving `record`: rv's words for the change and
    /// the fingerprint the terminal shows, never the agent's text. Escaped
    /// for an approval prompt; a command too long to show whole is named
    /// by fingerprint only, never cut.
    package static func prompt(for record: LoosenProposal) -> String {
        let looser = DisplayedText.approvalField(record.change.looser)
        let full = "approve rv proposal \(record.id): \(looser) [\(record.fingerprint)]"
        if full.unicodeScalars.count <= ConfirmOwnerActionParams.maxSummaryBytes { return full }
        return "approve rv proposal \(record.id): an allowlist exception for the exact command shown in your terminal [\(record.fingerprint)]"
    }

    package static func authorization(presence: ConfirmOwnerActionReply.Presence?, id: ProposalID) -> String {
        let how = presence == .password ? "login password, checked by rvd" : "Touch ID or password at rvd's prompt"
        return "owner (\(how)), proposal \(id)"
    }

    package static func item(_ record: LoosenProposal) -> ProposalItem {
        ProposalItem(
            id: record.id, change: record.change, from: record.from, cwd: record.cwd,
            createdAtMs: milliseconds(record.createdAt), contentHash: record.contentHash, status: record.status,
            decidedAtMs: record.decidedAt.map(milliseconds), declineReason: record.declineReason)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        let ms = (date.timeIntervalSince1970 * 1000).rounded()
        guard ms.isFinite, abs(ms) < 9.2e18 else { return 0 }
        return Int64(ms)
    }

    private static func applyProblem(_ error: Error) -> String {
        switch error {
        case let unrecorded as ConfigChangeUnrecorded: return unrecorded.description
        case OwnerConfigWriteError.unreadable: return "the config file it changes cannot be read; fix or remove it first"
        case OwnerConfigWriteError.unwritable: return "the config file it changes cannot be written"
        case LoosenProposalError.invalid(let problem): return problem
        default: return "the change could not be written"
        }
    }

    private func announce(_ record: LoosenProposal, at time: Date) {
        publish(
            .proposal(LiveProposal(id: record.id, status: record.status, kind: record.change.kind, from: record.from)),
            time)
    }

    private func refusal(
        _ error: LoosenProposalError, id: ProposalID, store: LoosenProposalStore, now: Date
    ) async -> DecideProposalReply {
        let current = await Self.offActor { () throws(LoosenProposalError) in
            try store.list(now: now).all.last(where: { $0.id == id })
        }
        let item = (try? current.get()).flatMap { $0 }.map(Self.item)
        switch error {
        case .notFound: return DecideProposalReply(outcome: .notFound)
        case .notPending: return DecideProposalReply(outcome: .notPending, proposal: item)
        case .changed: return DecideProposalReply(outcome: .changed, proposal: item)
        case .invalid(let problem): return DecideProposalReply(outcome: .invalid, proposal: item, problem: problem)
        case .applyFailed(let problem): return DecideProposalReply(outcome: .applyFailed, proposal: item, problem: problem)
        case .full, .unavailable: return DecideProposalReply(outcome: .unavailable)
        }
    }

    /// Store work takes file locks: off the `ServiceRuntime` actor, which
    /// hook evaluation also enters.
    private static func offActor<T: Sendable>(
        _ body: @escaping @Sendable () throws(LoosenProposalError) -> T
    ) async -> Result<T, LoosenProposalError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do throws(LoosenProposalError) {
                    continuation.resume(returning: .success(try body()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }
}
