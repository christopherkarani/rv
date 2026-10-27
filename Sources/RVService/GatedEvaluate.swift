import Foundation
import RVDomain
import RVEngine
import RVFileStore
import RVHistory
import RVPolicy

/// Peek shows a matching grant without consuming it. Apply spends it.
public enum EvaluationIntent: Sendable, Equatable {
    case peek
    case apply
}

/// Policy-gate verb after the Evaluate session.
private enum PolicyVerb: Sendable {
    case peek
    case apply

    var recordsDenial: Bool {
        switch self {
        case .peek:
            false
        case .apply:
            true
        }
    }
}

/// Evaluates a command through the Evaluate session, then the Policy gate.
public struct GatedEvaluate: Sendable {
    public var corePacksReady: Bool { resolvedSession().corePacksReady }

    private enum Source: Sendable {
        case prepared(EvaluateSession)
        case deferred(
            build: @Sendable () -> EvaluateSession,
            slot: UnfairLock<EvaluateSession?>
        )
    }

    private let source: Source

    /// Creates a door around an Evaluate session.
    public init(_ session: EvaluateSession = EvaluateSession()) {
        self.source = .prepared(session)
    }

    /// Creates a door that defers session construction until first use, then reuses it.
    package init(lazySession: @escaping @Sendable () -> EvaluateSession) {
        self.source = .deferred(
            build: lazySession,
            slot: UnfairLock(nil)
        )
    }

    private func resolvedSession() -> EvaluateSession {
        switch source {
        case .prepared(let session):
            return session
        case .deferred(let build, let slot):
            return slot.withLock { stored in
                if let stored {
                    return stored
                }
                let built = build()
                stored = built
                return built
            }
        }
    }

    /// Catalog-only file-tool door. Packs and Policy gate never see the path.
    public func runFile(
        _ action: FileToolAction,
        home: HomeDirectory? = nil,
        cwd: WorkingDirectory? = nil,
        host: LedgerHost = .tty,
        now: Date = Date()
    ) -> EvaluationResult {
        let workspace = Self.workspaceURL(cwd: cwd)
        let detailed = SecretAllowPaths.loadEffectiveDetailed(home: home, workspace: workspace)
        Self.auditDroppedRepoLiterals(
            detailed.droppedRepoLiterals,
            home: home,
            workspace: workspace,
            now: now
        )
        let result = evaluateFileTool(
            action,
            secretPaths: SecretPathDecider(
                allowPaths: detailed.effective,
                home: home,
                resolution: SecretPathCandidateResolver.resolution(
                    home: home,
                    cwd: cwd
                )
            )
        )
        // Observe is whole-guard: the file door logs-and-allows too,
        // and records no denial.
        if JudgeRuntime.guardMode(home: home) == .observe {
            return EvaluationResult(
                outcome: .plain,
                matchingView: result.matchingView,
                analysis: result.analysis
            )
        }
        recordDenialIfNeeded(
            result,
            path: action.path.rawValue,
            home: home,
            host: host,
            tool: .file(action.kind),
            now: now
        )
        return result
    }

    /// Trampoline onto `peek(command:)` or `apply(command:)`.
    ///
    /// `allowlist` is invoked only on deny (T13: allow/indeterminate skip allowlist I/O).
    public func run(
        _ intent: EvaluationIntent,
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash
    ) async -> EvaluationResult {
        switch intent {
        case .peek:
            await peek(
                command: command,
                cwd: cwd,
                home: home,
                grants: grants,
                now: now,
                allowlist: allowlist,
                host: host,
                tool: tool
            )
        case .apply:
            await apply(
                command: command,
                cwd: cwd,
                home: home,
                grants: grants,
                now: now,
                allowlist: allowlist,
                host: host,
                tool: tool
            )
        }
    }

    /// Shows a matching grant without spending it. TTY `test` / `explain`.
    public func peek(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash
    ) async -> EvaluationResult {
        await peek(
            Self.makeRequest(command: command, home: home),
            cwd: cwd,
            home: home,
            grants: grants,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool
        )
    }

    /// Spends a matching grant. Hook / `rvd` / in-process fallback.
    public func apply(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash
    ) async -> EvaluationResult {
        await apply(
            Self.makeRequest(command: command, home: home),
            cwd: cwd,
            home: home,
            grants: grants,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool
        )
    }

    /// Walk set for peek/apply and the XPC wire request. Nil home is day-one walk.
    public static func makeRequest(
        command: ShellCommand,
        home: HomeDirectory? = nil
    ) -> EvaluationRequest {
        EvaluationRequest(
            command: command,
            enabledPacks: EvaluationWorld.walkedPackIDs(home: home).ids
        )
    }

    /// Wire-path peek for an already-built request (ServiceRuntime explain/classify).
    /// CLI and in-process fallback must use `peek(command:)` so pack resolution stays shared.
    func peek(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash
    ) async -> EvaluationResult {
        await gated(
            PolicyVerb.peek,
            request,
            cwd: cwd,
            home: home,
            grants: grants,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool
        )
    }

    /// Wire-path apply for an already-built request (ServiceRuntime evaluate).
    /// CLI and in-process fallback must use `apply(command:)` so pack resolution stays shared.
    func apply(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash
    ) async -> EvaluationResult {
        await gated(
            PolicyVerb.apply,
            request,
            cwd: cwd,
            home: home,
            grants: grants,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool
        )
    }

    private func gated(
        _ verb: PolicyVerb,
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost,
        tool: LedgerTool
    ) async -> EvaluationResult {
        // Observe: evaluate everything, log the would-be verdict, allow.
        // Grants are never spent and denials never recorded on this path.
        if JudgeRuntime.guardMode(home: home) == .observe {
            var wouldBe = evaluateWithSemantics(request, cwd: cwd, home: home, now: now)
            var allowLane = true
            if case .allow = wouldBe.decision {
                switch scriptVerdict(for: request, cwd: cwd, home: home, now: now) {
                case .deny(let hit):
                    wouldBe = Self.projectScriptHit(hit, over: wouldBe)
                case .unresolved:
                    allowLane = false
                case .clear:
                    break
                }
            }
            return JudgeRuntime.observe(
                wouldBe: wouldBe, command: request.command, home: home,
                provenance: request.provenance, now: now, cwd: cwd,
                allowSafeLane: allowLane, isPeek: verb == .peek
            )
        }
        let result = evaluateWithSemantics(request, cwd: cwd, home: home, now: now)
        // Order matters: the script check and the judge run BEFORE the
        // Policy gate, and the gate then sees the final deny exactly
        // once. A judge/script Ask can therefore redeem the grant its
        // approval plants (no infinite Ask loop), and an allow-once
        // grant for a pack deny is never spent on a result the judge
        // would have re-denied afterwards.
        let candidate = applyScriptAndJudge(
            to: result, request: request, cwd: cwd, home: home, now: now,
            isPeek: verb == .peek
        )
        // Fast path: allow/indeterminate never touch PolicyGate or the
        // allowlist loader; PolicyGate returns them unchanged anyway.
        let finished: EvaluationResult
        switch candidate.decision {
        case .allow, .indeterminate:
            finished = candidate
        case .deny:
            if HookAuthorization.policyGateAccess(for: candidate) == .skip {
                finished = candidate
            } else {
                let snapshot = allowlist()
                let rebasing = GitRebaseProbe.rebaseInProgress(cwd: cwd)
                let safety = SafetyStore.loadEffective(
                    home: home,
                    workspace: Self.workspaceURL(cwd: cwd)
                )
                finished = await Self.applyPolicy(
                    verb,
                    result: candidate,
                    cwd: cwd,
                    snapshot: snapshot,
                    grants: grants,
                    now: now,
                    rebaseInProgress: rebasing,
                    safety: safety,
                    maskedSegments: Normalize.maskedSegments(of: request.command),
                    invocationPrefix: Normalize.invocationPrefix(of: request.command)
                )
            }
        }
        if verb.recordsDenial {
            recordDenialIfNeeded(finished, path: nil, home: home, host: host, tool: tool, now: now)
        }
        return finished
    }

    /// Script check, then judge, over a pack-allow. Anything else is
    /// returned untouched: a pack deny is a floor neither may lower.
    private func applyScriptAndJudge(
        to result: EvaluationResult,
        request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        now: Date,
        isPeek: Bool
    ) -> EvaluationResult {
        guard case .allow = result.decision else { return result }
        var allowLane = true
        switch scriptVerdict(for: request, cwd: cwd, home: home, now: now) {
        case .deny(let hit):
            return Self.projectScriptHit(hit, over: result)
        case .unresolved:
            allowLane = false
        case .clear:
            break
        }
        return JudgeRuntime.apply(
            to: result, command: request.command, home: home,
            provenance: request.provenance, now: now, cwd: cwd,
            allowSafeLane: allowLane, isPeek: isPeek
        )
    }

    private static func projectScriptHit(
        _ hit: EvaluationResult, over base: EvaluationResult
    ) -> EvaluationResult {
        EvaluationResult(
            outcome: hit.outcome,
            matchingView: base.matchingView,
            analysis: base.analysis,
            boundReview: hit.boundReview
        )
    }

    private func scriptVerdict(
        for request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        now: Date
    ) -> PackageScriptGate.Verdict {
        PackageScriptGate.evaluate(command: request.command, cwd: cwd, home: home) { body, packageCwd in
            let bodyRequest = EvaluationRequest(
                command: body,
                enabledPacks: request.enabledPacks,
                budget: request.budget,
                provenance: request.provenance
            )
            return evaluateWithSemantics(bodyRequest, cwd: packageCwd, home: home, now: now)
        }
    }

    private static func applyPolicy(
        _ verb: PolicyVerb,
        result: EvaluationResult,
        cwd: WorkingDirectory?,
        snapshot: AllowlistSnapshot,
        grants: EphemeralAllowOnceTable,
        now: Date,
        rebaseInProgress: Bool,
        safety: SafetyLevel,
        maskedSegments: [String]?,
        invocationPrefix: [String]
    ) async -> EvaluationResult {
        switch verb {
        case .peek:
            return await PolicyGate.preview(
                for: result,
                cwd: cwd,
                allowlist: snapshot,
                grants: grants,
                now: now,
                rebaseInProgress: rebaseInProgress,
                safety: safety,
                maskedSegments: maskedSegments,
                invocationPrefix: invocationPrefix
            ).result
        case .apply:
            return await PolicyGate.consumingGrant(
                for: result,
                cwd: cwd,
                allowlist: snapshot,
                grants: grants,
                now: now,
                rebaseInProgress: rebaseInProgress,
                safety: safety,
                maskedSegments: maskedSegments,
                invocationPrefix: invocationPrefix
            ).result
        }
    }

    /// Policy-store I/O (safety, secret allow-paths, typed rules) around the
    /// Engine evaluation door. The door owns evaluate → unwrap → probe →
    /// analyze → apply; the Policy gate runs after, in `gated`.
    /// Phase 2A has no principal-bound human grant transaction. Evaluate the
    /// canonical packs and hard policy without reading or consuming owner grants.
    /// A denied action stays denied until that separate authority flow exists.
    /// The script check and judge DO apply here — the guard is whole, on
    /// every door; only grant redemption is absent.
    func evaluateAgent(
        _ request: EvaluationRequest, cwd: WorkingDirectory?, home: HomeDirectory?
    ) -> EvaluationResult {
        let now = Date()
        let result = evaluateWithSemantics(request, cwd: cwd, home: home, now: now)
        if JudgeRuntime.guardMode(home: home) == .observe {
            var wouldBe = result
            var allowLane = true
            if case .allow = result.decision {
                switch scriptVerdict(for: request, cwd: cwd, home: home, now: now) {
                case .deny(let hit):
                    wouldBe = Self.projectScriptHit(hit, over: result)
                case .unresolved:
                    allowLane = false
                case .clear:
                    break
                }
            }
            return JudgeRuntime.observe(
                wouldBe: wouldBe, command: request.command, home: home,
                provenance: request.provenance, now: now, cwd: cwd,
                allowSafeLane: allowLane
            )
        }
        return applyScriptAndJudge(
            to: result, request: request, cwd: cwd, home: home, now: now, isPeek: false
        )
    }

    private func evaluateWithSemantics(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        now: Date = Date()
    ) -> EvaluationResult {
        let workspace = Self.workspaceURL(cwd: cwd)
        let detailed = SecretAllowPaths.loadEffectiveDetailed(home: home, workspace: workspace)
        Self.auditDroppedRepoLiterals(
            detailed.droppedRepoLiterals,
            home: home,
            workspace: workspace,
            now: now
        )
        let policy: EffectiveActionPolicy
        do {
            policy = EffectiveActionPolicy(rules: try Self.loadTypedRules(cwd: cwd, home: home))
        } catch {
            return EvaluationResult(
                outcome: .deny(
                    Deny(
                        ruleID: RuleID(
                            pack: ActionPolicyEngine.Builtin.pack,
                            pattern: "typed-rules-invalid"
                        ),
                        reason: "Typed rules could not be loaded."
                    ),
                    matched: nil
                ),
                matchingView: Normalize.matchingView(of: request.command)
            )
        }
        let secretPaths = SecretPathDecider(
            safety: SafetyStore.loadEffective(home: home, workspace: workspace),
            allowPaths: detailed.effective,
            home: home
        )
        func run(_ secretPaths: SecretPathDecider) -> EvaluationResult {
            resolvedSession().evaluateWithSemantics(
                request,
                secretPaths: secretPaths,
                workingDirectory: cwd,
                gitProbe: { unwrapped in
                    GitLiveProbe.world(unwrapped: unwrapped, fallbackCwd: cwd)
                },
                filesystemProbe: { unwrapped in
                    FilesystemLiveProbe.context(
                        unwrapped: unwrapped,
                        command: request.command,
                        cwd: cwd,
                        homeDirectory: home
                    )
                },
                policy: policy
            )
        }
        // First pass without resolution: packs and semantics own their
        // denials with the rich analysis they attach. Only when that pass
        // would allow does the alias-resolution seam run, escalating allows
        // whose candidates really land on secret paths (F-2: symlinks
        // disarming path rules must not buy an allow).
        let stance = run(secretPaths)
        guard secretPaths.escalatesToAliasPass(stance) else { return stance }
        return run(secretPaths.withResolution(
            SecretPathCandidateResolver.resolution(home: home, cwd: cwd)))
    }

    /// Machine from `$HOME/.config/rv`; repo from `<cwd>/.rv`. Missing file is empty.
    /// Missing HOME skips machine and still loads repo when cwd is present.
    private static func loadTypedRules(
        cwd: WorkingDirectory?,
        home: HomeDirectory?
    ) throws -> [TypedRule] {
        try PolicyWorkspace(home: home, workspace: workspaceURL(cwd: cwd))
            .loadEffectiveRules(builtin: [])
    }

    /// After apply stayed deny. Not peek. Not Ask. Nil when the deny is not unlockable.
    /// Missing HOME has no durable store `rv allow-once` can redeem, so skip the code.
    public static func mintUnlockCode(
        for result: EvaluationResult,
        cwd: WorkingDirectory?,
        store: AllowOnceStore,
        now: Date,
        home: HomeDirectory?,
        maskedSegments: [String]? = nil,
        invocationPrefix: [String] = [],
        invocationDisplay: String? = nil
    ) async -> AllowOnceUnlockMint? {
        guard home != nil else { return nil }
        guard let cwd, HookAuthorization.shouldMintUnlock(result: result, cwd: cwd) else {
            return nil
        }
        guard case .deny(let deny) = result.decision else { return nil }
        return await store.mintFromDeny(
            matchingView: result.matchingView,
            cwd: cwd,
            ruleID: deny.ruleID,
            now: now,
            maskedSegments: maskedSegments,
            invocationPrefix: invocationPrefix,
            invocationDisplay: invocationDisplay
        )
    }

    private static func workspaceURL(cwd: WorkingDirectory?) -> URL? {
        cwd.map { URL(fileURLWithPath: $0.rawValue, isDirectory: true) }
    }

    private func recordDenialIfNeeded(
        _ result: EvaluationResult,
        path: String?,
        home: HomeDirectory?,
        host: LedgerHost,
        tool: LedgerTool,
        now: Date
    ) {
        guard case .deny(let deny, let matched) = result.outcome else { return }
        guard let home else { return }
        let configDir = RVPolicyPaths.configDirectory(home: home)
        guard DenialLedgerPreferences.isEnabled(inConfigDirectory: configDir) else { return }
        let rawPath: String
        if let path, path.isEmpty == false {
            rawPath = path
        } else if let text = matched?.matchedText,
                  SecretPathCatalog.dayOne.firstMatch(of: text) != nil
        {
            rawPath = text
        } else {
            rawPath = ""
        }
        let category: LedgerCategory
        if let text = matched?.matchedText,
           let rule = SecretPathCatalog.dayOne.firstMatch(of: text)
        {
            category = .secret(rule.category)
        } else {
            category = .pack(deny.ruleID.pack)
        }
        DenialLedger(configDirectory: configDir).append(
            DenialLedgerRecord(
                timestamp: now,
                host: host,
                tool: tool,
                ruleID: deny.ruleID,
                category: category,
                path: DenialPathRedaction.redact(rawPath, home: home)
            ),
            now: now
        )
    }
}

extension GatedEvaluate {
    /// One JSONL row in `exemption-drops.jsonl`: repo-layer literals dropped
    /// for lack of machine blessing at one evaluation. Dropped literals are
    /// exemption patterns from `policy.toml`, never secret values.
    ///
    /// The boundary-check audit is borrowed from OpenShell: a candidate that
    /// allows beyond the boundary is reported, not applied.
    /// https://docs.nvidia.com/openshell/latest/how-it-works/policies/prover
    struct ExemptionDropRecord: Sendable, Equatable, Codable {
        var dropped: [String]
        var workspace: String?
        var recordedAt: TimeInterval
    }

    static let exemptionDropsFileName = "exemption-drops.jsonl"

    static func exemptionDropsFileURL(home: HomeDirectory) -> URL {
        RVPolicyPaths.exemptionDropsFile(
            inConfigDir: RVPolicyPaths.configDirectory(home: home))
    }

    /// Best-effort post-evaluation audit write: lock, I/O, or encode failures
    /// drop the row silently. Enforcement is unaffected — the effective set
    /// stands whether or not the audit row persists. Nil home or an empty
    /// dropped set writes nothing. Rows prune to `RVHistory.maxRows`, newest
    /// last. The row describes repo policy state observed at evaluation, not
    /// the decision, so peek audits the same as apply.
    ///
    /// Backed by `FileLockedJSONLStore` (cross-process `LOCK_EX` around
    /// load-modify-save): rvd, hook processes, and CLI fallback evaluate
    /// concurrently, and the previous in-process-lock rewrite lost rows to
    /// last-writer-wins between processes. A row identical in dropped set
    /// and workspace to the newest row is suppressed, so repeated hook
    /// checks against one unblessed repo cannot churn the cap and evict
    /// other workspaces' history.
    static func auditDroppedRepoLiterals(
        _ dropped: [String],
        home: HomeDirectory?,
        workspace: URL?,
        now: Date
    ) {
        guard dropped.isEmpty == false, let home else { return }
        let store = FileLockedJSONLStore<ExemptionDropRecord>(
            baseDirectory: RVPolicyPaths.configDirectory(home: home),
            fileName: exemptionDropsFileName
        )
        _ = try? store.withLock {
            var rows = store.load()
            if let last = rows.last,
                last.dropped == dropped,
                last.workspace == workspace?.path
            {
                return
            }
            rows.append(
                ExemptionDropRecord(
                    dropped: dropped,
                    workspace: workspace?.path,
                    recordedAt: now.timeIntervalSince1970
                )
            )
            try store.save(Array(rows.suffix(RVHistory.maxRows)))
        }
    }
}
