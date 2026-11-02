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
    private let judge: any JudgePort

    /// Creates a door around an Evaluate session.
    public init(_ session: EvaluateSession = EvaluateSession()) {
        self.init(session, judge: LiveJudgePort())
    }

    /// Creates a door around an Evaluate session with an explicit judge.
    init(_ session: EvaluateSession, judge: any JudgePort) {
        self.source = .prepared(session)
        self.judge = judge
    }

    /// Creates a door that defers session construction until first use, then reuses it.
    package init(lazySession: @escaping @Sendable () -> EvaluateSession) {
        self.source = .deferred(
            build: lazySession,
            slot: UnfairLock(nil)
        )
        self.judge = LiveJudgePort()
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
        runFile(
            action, home: home, cwd: cwd, host: host, now: now,
            guardMode: JudgeRuntime.guardMode(home: home)
        )
    }

    /// File door with guard mode already read for this evaluation.
    func runFile(
        _ action: FileToolAction,
        home: HomeDirectory?,
        cwd: WorkingDirectory?,
        host: LedgerHost,
        now: Date,
        guardMode: GuardMode
    ) -> EvaluationResult {
        let decided = decideFile(action, home: home, cwd: cwd, host: host, now: now, guardMode: guardMode)
        Self.perform(decided.effects, home: home)
        return decided.result
    }

    /// File-door decision: the verdict plus the writes it asks for, in order.
    func decideFile(
        _ action: FileToolAction,
        home: HomeDirectory?,
        cwd: WorkingDirectory?,
        host: LedgerHost,
        now: Date,
        guardMode: GuardMode
    ) -> (result: EvaluationResult, effects: [GatedEffect]) {
        let workspace = Self.workspaceURL(cwd: cwd)
        let detailed = SecretAllowPaths.loadEffectiveDetailed(home: home, workspace: workspace)
        var effects: [GatedEffect] = []
        if let audit = Self.exemptionAudit(detailed.droppedRepoLiterals, workspace: workspace, now: now) {
            effects.append(audit)
        }
        let result = evaluateFileTool(
            action,
            allowPaths: detailed.effective,
            home: home,
            pathResolution: SecretPathCandidateResolver.resolution(
                home: home,
                cwd: cwd
            )
        )
        switch posture(result, door: .file, guardMode: guardMode, cwd: cwd, home: home, now: now, effects: &effects) {
        case .observed(let observed):
            return (observed, effects)
        case .enforced(let enforced):
            // Checked on every enforced result, exactly as before effects
            // became values: past the deadline the check trips it, so
            // `HookDoor` swaps in the timeout deny even for an allow.
            guard HookDeadline.permitsSideEffects() else { return (enforced, effects) }
            if let row = Self.denialRow(
                for: enforced, path: action.path.rawValue, host: host, tool: .file(action.kind), now: now
            ) {
                effects.append(row)
            }
            return (enforced, effects)
        }
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
            .peek,
            request,
            cwd: cwd,
            home: home,
            grants: grants,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool,
            inputs: Self.liveInputs(home: home, cwd: cwd)
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
            .apply,
            request,
            cwd: cwd,
            home: home,
            grants: grants,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool,
            inputs: Self.liveInputs(home: home, cwd: cwd)
        )
    }

    /// The shell read: process env once, then config and stores once.
    private static func liveInputs(home: HomeDirectory?, cwd: WorkingDirectory?) -> EvaluationInputs {
        EvaluationInputs.gather(
            home: home,
            cwd: cwd,
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// Gated evaluate. `inputs` is gathered exactly once per evaluation,
    /// off the cooperative pool together with the evaluation, script check
    /// and judge (the shell doors pass a live gather; tests pass a value).
    func gated(
        _ intent: EvaluationIntent,
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost,
        tool: LedgerTool,
        inputs: @autoclosure @escaping @Sendable () -> EvaluationInputs
    ) async -> EvaluationResult {
        let decided = await decide(
            intent, request, cwd: cwd, home: home, grants: grants, now: now,
            allowlist: allowlist, host: host, tool: tool, inputs: inputs()
        )
        Self.perform(decided.effects, home: home)
        return decided.result
    }

    /// Shell-door decision: the verdict plus the writes it asks for, in
    /// order. Grant spend / preview stays inline here (SEC-003). `inputs`
    /// is gathered once, inside the offload.
    func decide(
        _ intent: EvaluationIntent,
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost,
        tool: LedgerTool,
        inputs: @autoclosure @escaping @Sendable () -> EvaluationInputs
    ) async -> (result: EvaluationResult, effects: [GatedEffect]) {
        let verb: PolicyVerb
        switch intent {
        case .peek:
            verb = .peek
        case .apply:
            verb = .apply
        }
        let isPeek = verb == .peek
        // Order matters: the script check and the judge run BEFORE the
        // Policy gate, and the gate then sees the final deny exactly
        // once. A judge/script Ask can therefore redeem the grant its
        // approval plants (no infinite Ask loop), and an allow-once
        // grant for a pack deny is never spent on a result the judge
        // would have re-denied afterwards.
        // The input reads, evaluation and judge steps block (file reads,
        // model load wait, inference): run them off the cooperative pool.
        // The Policy gate and every `HookDeadline` check stay here, where
        // the task-local deadline is bound.
        // The effects the offloaded steps ask for (exemption audit, judge
        // log) come back out of the closure, in order, with the result;
        // the denial row is appended after the Policy gate, here.
        let (screened, safety, offloaded) = await JudgeOffload.run { [self] in
            let gathered = inputs()
            var effects: [GatedEffect] = []
            let result = evaluateWithSemantics(
                request, cwd: cwd, home: home, store: gathered.store, now: now, effects: &effects
            )
            let screened = posture(
                result,
                door: .shell(request, inputs: gathered, isPeek: isPeek),
                guardMode: gathered.guardMode,
                cwd: cwd,
                home: home,
                now: now,
                effects: &effects
            )
            return (screened, gathered.store.safety, effects)
        }
        var effects = offloaded
        let candidate: EvaluationResult
        switch screened {
        case .observed(let observed):
            return (observed, effects)
        case .enforced(let enforced):
            candidate = enforced
        }
        // Fast path: allow/indeterminate never touch PolicyGate or the
        // allowlist loader; PolicyGate returns them unchanged anyway.
        let finished: EvaluationResult
        switch candidate.decision {
        case .allow, .indeterminate:
            finished = candidate
        case .deny:
            if HookAuthorization.policyGateAccess(for: candidate) == .skip {
                finished = candidate
            } else if verb == .apply, HookDeadline.permitsSideEffects() == false {
                // The hook client already gave up: spending the human's
                // allow-once grant on a reply nobody reads would burn it.
                finished = candidate
            } else {
                let snapshot = allowlist()
                let rebasing = GitRebaseProbe.rebaseInProgress(cwd: cwd)
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
        // On the task, after the offload (`HookDeadline.current` is
        // task-local). Checked on every apply, allow included: past the
        // deadline the check trips it and `HookDoor` swaps in the timeout
        // deny, so no denial row is emitted for a reply nobody reads.
        if verb.recordsDenial, HookDeadline.permitsSideEffects(),
           let row = Self.denialRow(for: finished, path: nil, host: host, tool: tool, now: now) {
            effects.append(row)
        }
        return (finished, effects)
    }

    /// Which door is asking. Shell doors run the script check and judge.
    private enum Door {
        case file
        case shell(EvaluationRequest, inputs: EvaluationInputs, isPeek: Bool)
    }

    /// `observed` is final: the door returns it as-is. `enforced` is what
    /// the door acts on (Policy gate, denial row).
    private enum Posture {
        case observed(EvaluationResult)
        case enforced(EvaluationResult)
    }

    /// The one observe/enforce branch, shared by every door.
    ///
    /// Observe is whole-guard: everything is evaluated, the would-be verdict
    /// is logged (shell doors, as a `.judgeLog` effect), and the door allows. Grants are never spent
    /// and denials never recorded on that path. Enforce runs the script
    /// check, then the judge, over a pack-allow; anything else is returned
    /// untouched (a pack deny is a floor neither may lower).
    private func posture(
        _ result: EvaluationResult,
        door: Door,
        guardMode: GuardMode,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        now: Date,
        effects: inout [GatedEffect]
    ) -> Posture {
        switch (guardMode, door) {
        case (.observe, .file):
            return .observed(result.observedAllow)
        case (.enforce, .file):
            return .enforced(result)
        case (.observe, .shell(let request, let inputs, let isPeek)):
            let screened = scriptScreen(
                result, request: request, cwd: cwd, home: home, inputs: inputs, now: now, effects: &effects
            )
            let observed = JudgeRuntime.observe(
                wouldBe: screened.result, command: request.command,
                inputs: inputs, judge: judge, provenance: request.provenance, now: now,
                cwd: cwd, allowSafeLane: screened.allowSafeLane, isPeek: isPeek
            )
            effects.append(.judgeLog(observed.log))
            return .observed(observed.result)
        case (.enforce, .shell(let request, let inputs, let isPeek)):
            let screened = scriptScreen(
                result, request: request, cwd: cwd, home: home, inputs: inputs, now: now, effects: &effects
            )
            if screened.scriptDenied {
                return .enforced(screened.result)
            }
            let judged = JudgeRuntime.apply(
                to: screened.result, command: request.command,
                inputs: inputs, judge: judge, provenance: request.provenance, now: now,
                cwd: cwd, allowSafeLane: screened.allowSafeLane, isPeek: isPeek
            )
            if let log = judged.log {
                effects.append(.judgeLog(log))
            }
            return .enforced(judged.result)
        }
    }

    /// Package-script check over a pack-allow. A script deny is projected
    /// over the pack result; an unresolved graph closes the safe lane.
    private struct ScriptScreen {
        let result: EvaluationResult
        let allowSafeLane: Bool
        let scriptDenied: Bool
    }

    private func scriptScreen(
        _ result: EvaluationResult,
        request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        inputs: EvaluationInputs,
        now: Date,
        effects: inout [GatedEffect]
    ) -> ScriptScreen {
        guard case .allow = result.decision else {
            return ScriptScreen(result: result, allowSafeLane: true, scriptDenied: false)
        }
        switch scriptVerdict(for: request, cwd: cwd, home: home, inputs: inputs, now: now, effects: &effects) {
        case .deny(let hit):
            return ScriptScreen(
                result: Self.projectScriptHit(hit, over: result), allowSafeLane: true, scriptDenied: true
            )
        case .unresolved:
            return ScriptScreen(result: result, allowSafeLane: false, scriptDenied: false)
        case .clear:
            return ScriptScreen(result: result, allowSafeLane: true, scriptDenied: false)
        }
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

    /// Script bodies in the request's workspace reuse the gathered store;
    /// a body in another package directory reads that directory's store.
    /// Each body's effects append in body evaluation order.
    private func scriptVerdict(
        for request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        inputs: EvaluationInputs,
        now: Date,
        effects: inout [GatedEffect]
    ) -> PackageScriptGate.Verdict {
        PackageScriptGate.evaluate(command: request.command, cwd: cwd, home: home) { body, packageCwd in
            let bodyRequest = EvaluationRequest(
                command: body,
                enabledPacks: request.enabledPacks,
                budget: request.budget,
                provenance: request.provenance
            )
            let store = packageCwd == cwd
                ? inputs.store
                : PolicyStoreInputs.gather(home: home, cwd: packageCwd)
            return evaluateWithSemantics(
                bodyRequest, cwd: packageCwd, home: home, store: store, now: now, effects: &effects
            )
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
            // The claim runs inside the grant table, atomically with the
            // spend: past the deadline the grant stays live for the retry,
            // and a grant spent in time keeps its allow even if the
            // deadline passes during the remaining steps.
            let deadline = HookDeadline.current
            return await PolicyGate.consumingGrant(
                for: result,
                cwd: cwd,
                allowlist: snapshot,
                grants: grants,
                now: now,
                rebaseInProgress: rebaseInProgress,
                safety: safety,
                maskedSegments: maskedSegments,
                invocationPrefix: invocationPrefix,
                claim: { deadline?.claimGrantSpend() ?? true }
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
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        now: Date = Date()
    ) -> EvaluationResult {
        evaluateAgent(
            request, cwd: cwd, home: home, now: now,
            inputs: Self.liveInputs(home: home, cwd: cwd)
        )
    }

    /// Agent door with inputs already gathered for this evaluation.
    func evaluateAgent(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        now: Date,
        inputs: EvaluationInputs
    ) -> EvaluationResult {
        let decided = decideAgent(request, cwd: cwd, home: home, now: now, inputs: inputs)
        Self.perform(decided.effects, home: home)
        return decided.result
    }

    /// Agent-door decision: the verdict plus the writes it asks for, in
    /// order. The agent door never records a denial row.
    func decideAgent(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        now: Date,
        inputs: EvaluationInputs
    ) -> (result: EvaluationResult, effects: [GatedEffect]) {
        var effects: [GatedEffect] = []
        let result = evaluateWithSemantics(
            request, cwd: cwd, home: home, store: inputs.store, now: now, effects: &effects
        )
        switch posture(
            result,
            door: .shell(request, inputs: inputs, isPeek: false),
            guardMode: inputs.guardMode,
            cwd: cwd,
            home: home,
            now: now,
            effects: &effects
        ) {
        case .observed(let final), .enforced(let final):
            return (final, effects)
        }
    }

    private func evaluateWithSemantics(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        store: PolicyStoreInputs,
        now: Date,
        effects: inout [GatedEffect]
    ) -> EvaluationResult {
        let workspace = Self.workspaceURL(cwd: cwd)
        // Peek audits the same as apply: the row describes repo policy
        // state observed at evaluation, not the decision.
        if let audit = Self.exemptionAudit(
            store.allowPaths.droppedRepoLiterals, workspace: workspace, now: now
        ) {
            effects.append(audit)
        }
        guard let policy = store.policy else {
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
        func run(_ pathResolution: SecretPathResolution?) -> EvaluationResult {
            resolvedSession().evaluateWithSemantics(
                request,
                safety: store.safety,
                allowPaths: store.allowPaths.effective,
                home: home,
                pathResolution: pathResolution,
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
        let stance = run(nil)
        switch stance.outcome {
        case .deny, .indeterminate:
            return stance
        case .quickRejected, .plain, .safeOnly, .hit:
            return run(SecretPathCandidateResolver.resolution(home: home, cwd: cwd))
        }
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

    /// The denial-ledger row a final deny asks for; nil for anything else.
    private static func denialRow(
        for result: EvaluationResult,
        path: String?,
        host: LedgerHost,
        tool: LedgerTool,
        now: Date
    ) -> GatedEffect? {
        guard case .deny(let deny, let matched) = result.outcome else { return nil }
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
        return .denialRow(GatedEffect.DenialRow(
            at: now, host: host, tool: tool, ruleID: deny.ruleID, category: category, path: rawPath
        ))
    }

    /// The exemption-drops row for one evaluation's dropped repo literals;
    /// nil when nothing was dropped.
    private static func exemptionAudit(_ dropped: [String], workspace: URL?, now: Date) -> GatedEffect? {
        guard dropped.isEmpty == false else { return nil }
        return .exemptionAudit(GatedEffect.ExemptionAudit(dropped: dropped, workspace: workspace, at: now))
    }

    /// The shell: applies one evaluation's effects in order. Missing home
    /// has no config directory, so nothing is written. The hook deadline
    /// is applied by the decision (no `.denialRow` is emitted past it);
    /// the exemption audit and judge log are not deadline-gated.
    static func perform(_ effects: [GatedEffect], home: HomeDirectory?) {
        guard let home else { return }
        for effect in effects {
            switch effect {
            case .exemptionAudit(let audit):
                auditDroppedRepoLiterals(audit.dropped, home: home, workspace: audit.workspace, now: audit.at)
            case .judgeLog(let row):
                JudgeRuntime.appendLog(row, home: home)
            case .denialRow(let row):
                recordDenial(row, home: home)
            }
        }
    }

    /// Appends a denial row when the ledger is enabled (`blocks.enabled`,
    /// read here, deny-only). The path is redacted against home.
    private static func recordDenial(_ row: GatedEffect.DenialRow, home: HomeDirectory) {
        let configDir = RVPolicyPaths.configDirectory(home: home)
        guard DenialLedgerPreferences.isEnabled(inConfigDirectory: configDir) else { return }
        DenialLedger(configDirectory: configDir).append(
            DenialLedgerRecord(
                timestamp: row.at,
                host: row.host,
                tool: row.tool,
                ruleID: row.ruleID,
                category: row.category,
                path: DenialPathRedaction.redact(row.path, home: home)
            ),
            now: row.at
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
