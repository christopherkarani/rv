import Foundation
import RVDomain
import RVPolicy

/// Phase 4 review queue: blocked CONNECTs become scoped proposals on the
/// shared pending-approval store, and human approvals load live into the
/// proxy. Owned by `WorkspaceSessionSupervisor` (one queue per host).
///
/// Reuse, no parallel system: proposals are `PendingApprovalStore` rows,
/// and per-approval single-application rides `EphemeralAllowOnceTable`
/// (one approval id plants at most once per epoch; `alreadyRedeemed`
/// skips duplicates without a second channel append). The queue adds no
/// grant store and no second review list.
///
/// Trust: the cage cannot forge approvals — the seatbelt profile denies
/// it the config directory, so only host-side writers resolve rows. A
/// same-user host process can already rewrite every static policy file,
/// so file-signal approvals add no privilege beyond existing config
/// trust; the `LocalControlBoundary` transition will move approval
/// authority into authenticated service routes when they land.
public actor NetworkReviewQueue {
    /// One proxy push: the full live set plus its generation. The proxy
    /// applies it only when the generation is newer (guard lives there).
    public struct AppliedUpdate: Sendable, Equatable {
        public var rules: Set<LiveNetworkRule>
        public var generation: UInt64
        public var approvalIDs: [String]

        public init(
            rules: Set<LiveNetworkRule>,
            generation: UInt64,
            approvalIDs: [String]
        ) {
            self.rules = rules
            self.generation = generation
            self.approvalIDs = approvalIDs
        }
    }

    private let store: PendingApprovalStore
    private let ceremonies: EphemeralAllowOnceTable
    private let channel: NetworkRuleLiveChannel
    /// Live-rule fingerprint to the proposal id minted for it. Rebuilt
    /// through ledger dedupe after a restart (see noteDenial).
    private var knownIDs: [String: String] = [:]
    private var appliedIDs: Set<String> = []

    public init(configDirectory: URL) {
        self.init(
            store: PendingApprovalStore(baseDirectory: configDirectory),
            ceremonies: EphemeralAllowOnceTable(),
            channel: NetworkRuleLiveChannel()
        )
    }

    init(
        store: PendingApprovalStore,
        ceremonies: EphemeralAllowOnceTable,
        channel: NetworkRuleLiveChannel
    ) {
        self.store = store
        self.ceremonies = ceremonies
        self.channel = channel
    }

    public var liveChannel: NetworkRuleLiveChannel {
        channel
    }

    /// Intake for one proxy denial. Only `.deniedPolicy` denials name a
    /// rule a human could approve: DNS, filter, dial, header, and
    /// malformed failures admit no rule (approving them would change
    /// nothing), and requests already covered by a live rule need none.
    ///
    /// Dedupe is two-layer: in-memory `knownIDs` skips re-checks for
    /// rows minted this lifetime, and ledger dedupe (same workspace
    /// identity plus fingerprint) collapses retry storms and rebuilds
    /// `knownIDs` after a restart by returning the awaiting row. A full
    /// store drops the proposal (spam protection, mirroring HookDoor):
    /// the denial still stands and the human path is unaffected.
    public func noteDenial(
        _ denial: EgressProxyDenial,
        workspace: WorkspaceSessionID,
        workspaceDirectory: WorkingDirectory,
        now: Date
    ) async {
        guard denial.reason == .deniedPolicy else { return }
        guard let rule = LiveNetworkRule(host: denial.host, port: denial.port) else { return }
        if channel.contains(rule) { return }
        let fingerprint = EgressProposal.fingerprint(for: rule).rawValue
        if let known = knownIDs[fingerprint],
            let record = try? await store.load(id: ApprovalID(rawValue: known), now: now)
        {
            switch record.state {
            case .awaitingHuman:
                return
            case .resolved(let resolution) where resolution.decision.authorizesExactAction:
                return
            case .consumed(let resolution, _) where resolution.decision.authorizesExactAction:
                return
            case .resolved, .consumed, .expired, .canceled, .timedOut:
                break
            }
        }
        guard
            let request = EgressProposal.request(
                id: PendingApprovalStore.makeID(),
                rule: rule,
                workspaceSession: workspace,
                workspaceDirectory: workspaceDirectory
            )
        else {
            return
        }
        do {
            let created = try await store.create(request, now: now)
            knownIDs[fingerprint] = created.id.rawValue
        } catch PendingApprovalError.storeFull {
            return
        } catch {
            return
        }
    }

    /// Apply newly-approved network rules to the live channel. Idempotent:
    /// each approval id appends at most once per epoch (ceremony plant),
    /// and terminal non-approvals (deny, expire, cancel, timeout) apply
    /// nothing, ever. Returns the proxy push, or nil when nothing moved.
    ///
    /// Exact-row bind: the stored fingerprint is file text, so the rule
    /// re-parses strictly from the loaded row and must equal the intake
    /// key; any drift fails closed (skip). A missing workspace scope does
    /// the same: the ceremony plant binds the grant cwd, and an unbound
    /// plant is refused.
    public func applyResolved(now: Date) async -> AppliedUpdate? {
        var newlyApplied: [String] = []
        for (fingerprint, idValue) in knownIDs {
            if appliedIDs.contains(idValue) { continue }
            guard let record = try? await store.load(id: ApprovalID(rawValue: idValue), now: now)
            else { continue }
            let authorizes: Bool
            switch record.state {
            case .resolved(let resolution), .consumed(let resolution, _):
                authorizes = resolution.decision.authorizesExactAction
            case .awaitingHuman, .expired, .canceled, .timedOut:
                authorizes = false
            }
            guard authorizes else { continue }
            guard record.fingerprint.rawValue == fingerprint,
                let rule = EgressProposal.rule(for: record),
                let cwd = record.action.scope.workingDirectory
            else { continue }
            let plant = await ceremonies.plant(
                fingerprint: GrantFingerprint(rawValue: fingerprint),
                cwd: cwd,
                codeHash: CodeHash(rawValue: "egress-approved:\(idValue)"),
                pendingID: ApprovalID(rawValue: idValue),
                now: now
            )
            switch plant {
            case .planted:
                break
            case .alreadyRedeemed, .refused:
                continue
            }
            _ = channel.append(rule)
            appliedIDs.insert(idValue)
            newlyApplied.append(idValue)
        }
        guard newlyApplied.isEmpty == false else { return nil }
        let snapshot = channel.snapshot()
        return AppliedUpdate(
            rules: snapshot.rules,
            generation: snapshot.generation,
            approvalIDs: newlyApplied.sorted()
        )
    }

    /// Record what the proxy accepted: the enforced generation plus the
    /// exact live set, for `rv egress` display. Call only after the proxy
    /// confirms acceptance; a refused push records nothing. Actor
    /// serialization keeps the file on the latest push. Best-effort
    /// display state: a failed encode or write never fails the sweep.
    public func recordLoaded(
        rules: Set<LiveNetworkRule>,
        generation: UInt64,
        approvalIDs: [String],
        now: Date
    ) {
        let snapshot = EgressLoadedSnapshot(
            generation: generation,
            rules: Array(rules),
            approvalIDs: approvalIDs.sorted(),
            updatedAt: now
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(
            to: RVPolicyPaths.egressLoadedSnapshotFile(inConfigDir: store.baseDirectory),
            options: .atomic
        )
    }
}
