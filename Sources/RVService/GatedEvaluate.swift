import Foundation
import RVDomain
import RVEngine
import RVFileStore
import RVHistory
import RVHooks
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

/// A gated peek: what the door returns, and under observe the verdict
/// enforce would have returned (`rv test` / `rv explain` show that one).
package struct GatedVerdict: Sendable, Equatable {
    /// The would-be verdict and how enforce would have authorized it.
    package struct WouldBe: Sendable, Equatable {
        /// Through a Policy-gate preview, as enforce would show it.
        package let result: EvaluationResult
        /// Ask, pinned deny or allow: the projection the observed denial
        /// row's `would_be` is taken from.
        package let authorization: HookAuthorization

        package init(result: EvaluationResult, authorization: HookAuthorization) {
            self.result = result
            self.authorization = authorization
        }
    }

    /// What the door returns (under observe, the observed allow).
    package let result: EvaluationResult
    /// Nil when the enforce branch decided: enforce mode, or a result the
    /// observe floor took.
    package let wouldBe: WouldBe?

    package init(result: EvaluationResult, wouldBe: WouldBe? = nil) {
        self.result = result
        self.wouldBe = wouldBe
    }

    /// The verdict to show: the would-be one under observe, else the result.
    package var shown: EvaluationResult { wouldBe?.result ?? result }

    /// Observe changed the outcome: enforce would have decided otherwise.
    package var observeOverrode: Bool {
        guard let wouldBe else { return false }
        return wouldBe.result.decision != result.decision
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
            guardMode: JudgeRuntime.effectiveGuardMode(
                home: home, host: host,
                environment: ProcessInfo.processInfo.environment,
                config: GuardConfig.read(home: home)
            )
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
        var result = evaluateFileTool(
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
        // Edit/Write to rv's own hook, service or binary files: the agent
        // must not unhook the guard watching it. Reads stay allowed.
        if case .allow = result.decision, action.kind != .read,
           WiringPathGuard.protects(action.path.rawValue, home: home, cwd: cwd) {
            result = WiringPathGuard.deny(path: action.path.rawValue)
        }
        // Edit/Write to a host MCP config while rv's MCP gateway is in use.
        if case .allow = result.decision, action.kind != .read,
           let guarded = MCPHostConfigDoor.hostConfigGuard(home: home, managed: ManagedGate.state(home: home, now: now)),
           MCPHostConfigDoor.protects(action.path.rawValue, guard: guarded, home: home, cwd: cwd) {
            result = MCPHostConfigDoor.deny(path: action.path.rawValue)
        }
        switch posture(result, door: .file(action), guardMode: guardMode, cwd: cwd, home: home, now: now, effects: &effects) {
        case .observed(let observed, let wouldBe, _):
            // `would_be` stays deny: the hook's file wire never asks
            // (`hookFileWire`).
            if let row = Self.denialRow(
                for: wouldBe, path: action.path.rawValue, host: host, tool: .file(action.kind), now: now,
                observed: true
            ) {
                effects.append(row)
            }
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

    /// `peek(command:)` plus, under observe, the verdict enforce would show.
    /// TTY `test` / `explain`.
    package func peekVerdict(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash
    ) async -> GatedVerdict {
        await gatedVerdict(
            .peek,
            Self.makeRequest(command: command, home: home),
            cwd: cwd,
            home: home,
            grants: grants,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool,
            previewsWouldBe: true,
            inputs: Self.liveInputs(home: home, cwd: cwd, host: host)
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
            inputs: Self.liveInputs(home: home, cwd: cwd, host: host)
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
            inputs: Self.liveInputs(home: home, cwd: cwd, host: host)
        )
    }

    /// Wire-path `apply` plus, under observe, the verdict enforce would
    /// return (ServiceRuntime evaluate, for SDK callers).
    func applyVerdict(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash
    ) async -> GatedVerdict {
        await gatedVerdict(
            .apply,
            request,
            cwd: cwd,
            home: home,
            grants: grants,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool,
            previewsWouldBe: true,
            inputs: Self.liveInputs(home: home, cwd: cwd, host: host)
        )
    }

    /// The shell read: process env once, then config and stores once.
    private static func liveInputs(
        home: HomeDirectory?, cwd: WorkingDirectory?, host: LedgerHost = .tty
    ) -> EvaluationInputs {
        EvaluationInputs.gather(
            home: home,
            cwd: cwd,
            environment: ProcessInfo.processInfo.environment,
            host: host
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
        await gatedVerdict(
            intent, request, cwd: cwd, home: home, grants: grants, now: now,
            allowlist: allowlist, host: host, tool: tool, previewsWouldBe: false, inputs: inputs()
        ).result
    }

    /// `gated` plus, under observe and when `previewsWouldBe`, the would-be
    /// verdict.
    func gatedVerdict(
        _ intent: EvaluationIntent,
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost,
        tool: LedgerTool,
        previewsWouldBe: Bool,
        inputs: @autoclosure @escaping @Sendable () -> EvaluationInputs
    ) async -> GatedVerdict {
        let decided = await decideVerdict(
            intent, request, cwd: cwd, home: home, grants: grants, now: now,
            allowlist: allowlist, host: host, tool: tool, previewsWouldBe: previewsWouldBe, inputs: inputs()
        )
        // Exemption audit and judge log are file appends: keep them off the
        // cooperative pool, as they were when they ran inside the offload.
        let effects = decided.effects
        let overridesRecorded = await HookTiming.measure(.effects) {
            await JudgeOffload.run { Self.perform(effects, home: home) }
        }
        let result = overridesRecorded ? decided.result : Self.unrecordedOverride(decided.result, effects: effects)
        return GatedVerdict(result: result, wouldBe: decided.wouldBe)
    }

    /// Why an override whose `command.override` row was not written stays a deny.
    static let unrecordedOverrideReason =
        "rv could not write the audit log, so the override of this deny was not applied"

    /// The deny an override turns back into when its audit row did not land:
    /// no unrecorded allow ever leaves the gate.
    private static func unrecordedOverride(_ result: EvaluationResult, effects: [GatedEffect]) -> EvaluationResult {
        for effect in effects {
            guard case .overrideAudit(let row) = effect else { continue }
            return EvaluationResult(
                outcome: .deny(Deny(ruleID: row.ruleID, reason: unrecordedOverrideReason), matched: nil),
                matchingView: result.matchingView, analysis: result.analysis
            )
        }
        return result
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
        let decided = await decideVerdict(
            intent, request, cwd: cwd, home: home, grants: grants, now: now,
            allowlist: allowlist, host: host, tool: tool, previewsWouldBe: false, inputs: inputs()
        )
        return (decided.result, decided.effects)
    }

    /// `decide` plus, under observe, the would-be verdict through a
    /// Policy-gate preview and its enforce authorization. Nil when the
    /// enforce branch decided, or when `previewsWouldBe` is false (the
    /// preview then runs only for an apply's observed denial row).
    func decideVerdict(
        _ intent: EvaluationIntent,
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost,
        tool: LedgerTool,
        previewsWouldBe: Bool,
        inputs: @autoclosure @escaping @Sendable () -> EvaluationInputs
    ) async -> (
        result: EvaluationResult,
        effects: [GatedEffect],
        wouldBe: GatedVerdict.WouldBe?
    ) {
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
        // (The hook-local evaluator gathers `inputs` before calling, on its
        // own thread, to record the guard mode it read; it makes one call
        // per process, so nothing else waits on that thread.)
        // The Policy gate and every `HookDeadline` check stay here, where
        // the task-local deadline is bound.
        // The effects the offloaded steps ask for (exemption audit, judge
        // log) come back out of the closure, in order, with the result;
        // the denial row is appended after the Policy gate, here.
        let (screened, safety, offloaded) = await JudgeOffload.run { [self] in
            let gathered = HookTiming.measure(.inputs) { inputs() }
            var effects: [GatedEffect] = []
            let result = HookTiming.measure(.policy) {
                evaluateWithSemantics(
                    request, cwd: cwd, home: home, store: gathered.store, now: now, effects: &effects
                )
            }
            let screened = HookTiming.measure(.screen) {
                posture(
                    result,
                    door: .shell(request, inputs: gathered, isPeek: isPeek),
                    guardMode: gathered.guardMode,
                    cwd: cwd,
                    home: home,
                    now: now,
                    effects: &effects
                )
            }
            return (screened, gathered.store.safety, effects)
        }
        var effects = offloaded
        let candidate: EvaluationResult
        switch screened {
        case .observed(let observed, let unfloored, let floorsWouldBe):
            // The would-be verdict through a Policy-gate preview (an
            // allowlist entry or live grant would have let it through;
            // nothing is spent): on apply, what enforcement would have
            // denied; for a verdict caller, what enforce would show. Other
            // peeks skip it. Not deadline-gated: the reply is an allow
            // either way, and checking would trip the deadline into a
            // timeout deny.
            var recordsDenial = false
            if verb.recordsDenial, case .deny = unfloored.decision { recordsDenial = true }
            if verb.recordsDenial, case .indeterminate = unfloored.decision, let row = Self.denialRow(
                for: unfloored, path: nil, host: host, tool: tool, now: now, observed: true,
                wouldBe: Self.ledgerWouldBe(HookAuthorization.project(result: unfloored, cwd: cwd))
            ) {
                // An unfinished evaluation enforcement would refuse. It never
                // reaches the Policy gate as a ledger row, not even a preview.
                effects.append(row)
            }
            guard recordsDenial || previewsWouldBe else { return (observed, effects, nil) }
            // The packs-only floor only turns an allow indeterminate, so it
            // never changes whether a denial row is recorded: it runs here,
            // where the would-be is consumed, not on every observed allow.
            let wouldBe = floorsWouldBe
                ? JudgeRuntime.packsOnlyFloor(unfloored, command: request.command)
                : unfloored
            let previewed = await Self.policyFinish(
                .peek, candidate: wouldBe, request: request, cwd: cwd, grants: grants,
                now: now, allowlist: allowlist, safety: safety
            )
            let authorization = HookAuthorization.project(result: previewed.result, cwd: cwd)
            if recordsDenial, let row = Self.denialRow(
                for: previewed.result, path: nil, host: host, tool: tool, now: now, observed: true,
                wouldBe: Self.ledgerWouldBe(authorization)
            ) {
                effects.append(row)
            }
            return (observed, effects, GatedVerdict.WouldBe(result: previewed.result, authorization: authorization))
        case .enforced(let enforced):
            candidate = enforced
        }
        let decision = await HookTiming.measure(.gate) {
            await Self.policyFinish(
                verb, candidate: candidate, request: request, cwd: cwd, grants: grants,
                now: now, allowlist: allowlist, safety: safety
            )
        }
        let finished = decision.result
        let override = decision.override
        // On the task, after the offload (`HookDeadline.current` is
        // task-local). Checked on every apply, allow included: past the
        // deadline the check trips it and `HookDoor` swaps in the timeout
        // deny, so no denial row is emitted for a reply nobody reads.
        let denialInTime = verb.recordsDenial && HookDeadline.permitsSideEffects()
        if denialInTime, let row = Self.denialRow(for: finished, path: nil, host: host, tool: tool, now: now) {
            effects.append(row)
        }
        // An allow-once grant spent in time keeps its reply even when the
        // deadline passes after (`HookDoor` sends no timeout deny then), so
        // the deny that reply becomes, if the override row fails, keeps its
        // rows too.
        if verb.recordsDenial,
           let row = Self.overrideAudit(candidate: candidate, finished: finished, override: override,
                                        host: host, tool: tool, cwd: cwd, now: now,
                                        withDenial: denialInTime || override == .allowOnce) {
            effects.append(row)
        }
        return (finished, effects, nil)
    }

    /// The Policy gate over a candidate verdict. Fast path: allow and
    /// indeterminate never touch PolicyGate or the allowlist loader;
    /// PolicyGate returns them unchanged anyway.
    private static func policyFinish(
        _ verb: PolicyVerb,
        candidate: EvaluationResult,
        request: EvaluationRequest,
        cwd: WorkingDirectory?,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        safety: SafetyLevel
    ) async -> (result: EvaluationResult, override: PolicyOverride) {
        switch candidate.decision {
        case .allow, .indeterminate:
            return (candidate, .none)
        case .deny:
            if HookAuthorization.policyGateAccess(for: candidate) == .skip {
                return (candidate, .none)
            }
            if verb == .apply, HookDeadline.permitsSideEffects() == false {
                // The hook client already gave up: spending the human's
                // allow-once grant on a reply nobody reads would burn it.
                return (candidate, .none)
            }
            let snapshot = allowlist()
            let rebasing = GitRebaseProbe.rebaseInProgress(cwd: cwd)
            let decision = await applyPolicy(
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
            return (decision.result, decision.override)
        }
    }

    /// Which door is asking. Shell doors run the script check and judge.
    private enum Door {
        case file(FileToolAction)
        case shell(EvaluationRequest, inputs: EvaluationInputs, isPeek: Bool)

        var observeFloor: ObserveFloor.Door {
            switch self {
            case .file(let action): .file(action)
            case .shell(let request, let inputs, _): .shell(request.command, store: inputs.store)
            }
        }
    }

    /// `observed` is final: the door returns it as-is; `wouldBe` is what
    /// enforcement would have acted on (observed denial row), before the
    /// packs-only floor when `floorsWouldBe`. `enforced` is what the door
    /// acts on (Policy gate, denial row).
    private enum Posture {
        case observed(EvaluationResult, wouldBe: EvaluationResult, floorsWouldBe: Bool)
        case enforced(EvaluationResult)
    }

    /// The one observe/enforce branch, shared by every door.
    ///
    /// Observe is whole-guard: everything is evaluated, the would-be verdict
    /// is logged (shell doors, as a `.judgeLog` effect), and the door allows. Grants are never spent
    /// on that path; apply and the file door record a would-be deny as an
    /// observed denial row. Enforce runs the script
    /// check, then the judge, over a pack-allow; anything else is returned
    /// untouched (a pack deny is a floor neither may lower).
    ///
    /// Observe never relaxes rv's own protection (`ObserveFloor.rule`):
    /// such a result takes the enforce branch, on every door, with the
    /// result the floor hands back. Stopping rvd, writing its install, or
    /// touching rv's protection only in program text the command feeds a
    /// shell is floored at "run it in Terminal" there (an allow becomes
    /// indeterminate; a deny stays the deny). Otherwise a shell command
    /// running a program rv cannot see is sent to Terminal
    /// (`observe.floor:unanalyzable`) whatever its verdict, since observe
    /// would have let it run.
    private func posture(
        _ evaluated: EvaluationResult,
        door: Door,
        guardMode: GuardMode,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        now: Date,
        effects: inout [GatedEffect]
    ) -> Posture {
        var result = evaluated
        var mode = guardMode
        if guardMode == .observe,
           case .enforce(let floored) = ObserveFloor.rule(
               evaluated, door: door.observeFloor, context: ObserveFloor.Context(home: home, cwd: cwd)
           )
        {
            result = floored
            mode = .enforce
        }
        switch (mode, door) {
        case (.observe, .file):
            return .observed(result.observedAllow, wouldBe: result, floorsWouldBe: false)
        case (.enforce, .file):
            return .enforced(result)
        case (.observe, .shell(let request, let inputs, let isPeek)):
            let screened = scriptScreen(
                result, request: request, cwd: cwd, home: home, inputs: inputs, now: now, effects: &effects
            )
            let observed = JudgeRuntime.observe(
                wouldBe: screened.result, command: request.command,
                inputs: inputs, judge: judge, provenance: request.provenance, now: now,
                cwd: cwd, allowSafeLane: screened.allowSafeLane, isPeek: isPeek,
                lateLog: Self.lateJudgeLog(home: home)
            )
            effects.append(.judgeLog(observed.log))
            return .observed(observed.result, wouldBe: observed.wouldBe, floorsWouldBe: observed.floorsWouldBe)
        case (.enforce, .shell(let request, let inputs, let isPeek)):
            let screened = scriptScreen(
                result, request: request, cwd: cwd, home: home, inputs: inputs, now: now, effects: &effects
            )
            if screened.scriptDenied {
                return .enforced(screened.result)
            }
            if inputs.judge.shadow {
                // Shadow judge: scored and logged as a would-be, never
                // decides; the packs' and script check's verdict stands.
                let shadowed = JudgeRuntime.observe(
                    wouldBe: screened.result, command: request.command,
                    inputs: inputs, judge: judge, provenance: request.provenance, now: now,
                    cwd: cwd, allowSafeLane: screened.allowSafeLane, isPeek: isPeek,
                    lateLog: Self.lateJudgeLog(home: home)
                )
                effects.append(.judgeLog(shadowed.log))
                return .enforced(screened.result)
            }
            let judged = JudgeRuntime.apply(
                to: screened.result, command: request.command,
                inputs: inputs, judge: judge, provenance: request.provenance, now: now,
                cwd: cwd, allowSafeLane: screened.allowSafeLane, isPeek: isPeek,
                lateLog: Self.lateJudgeLog(home: home)
            )
            if let log = judged.log {
                effects.append(.judgeLog(log))
            }
            return .enforced(judged.result)
        }
    }

    /// Where a prediction that answered after its caller gave up is logged:
    /// straight to the judge log, since the request's effects are long
    /// performed by then. nil without a home (nothing to log to).
    private static func lateJudgeLog(home: HomeDirectory?) -> (@Sendable (GatedEffect.JudgeLogRow) -> Void)? {
        guard let home else { return nil }
        return { @Sendable row in JudgeRuntime.appendLog(row, home: home) }
    }

    /// Package-script check over a pack-allow. A script deny is projected
    /// over the pack result; an unresolved graph is indeterminate before
    /// any judge runs. `scriptDenied` means the screen's result is final.
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
            // Nobody has read what this runner executes. The judge only
            // ever sees the top-level string (`npm test`), so it cannot
            // vouch for the graph either: a human decides, judge or not.
            // Depth, cycle and evaluation caps all land here.
            return ScriptScreen(
                result: EvaluationResult(
                    outcome: .indeterminate(.packageScriptUnresolved),
                    matchingView: result.matchingView,
                    analysis: result.analysis
                ),
                allowSafeLane: false, scriptDenied: true
            )
        case .needsJudge:
            // A package bin, a remote runner, or a run after earlier work
            // with no script to run: no body the judge cannot see, so the
            // judge decides from the whole command, never the safe lane.
            return ScriptScreen(result: result, allowSafeLane: false, scriptDenied: false)
        case .clear(let allBodiesSafe):
            // A body that is not itself safe-lane (`jest`, `node x.js`)
            // keeps the command in front of the judge.
            return ScriptScreen(result: result, allowSafeLane: allBodiesSafe, scriptDenied: false)
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
    ) async -> PolicyDecision {
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
            )
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
            )
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
        case .observed(let final, _, _), .enforced(let final):
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
                        ruleID: BuiltinRule.typedRulesInvalid.ruleID,
                        reason: "Typed rules could not be loaded."
                    ),
                    matched: nil
                ),
                matchingView: Normalize.matchingView(of: request.command)
            )
        }
        let secretPaths = SecretPathDecider(
            safety: store.safety,
            allowPaths: store.allowPaths.effective,
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
                    attachingMCPHostConfigGuard(
                        store.mcpHostConfigGuard,
                        to: FilesystemLiveProbe.context(
                            unwrapped: unwrapped,
                            command: request.command,
                            cwd: cwd,
                            homeDirectory: home
                        ),
                        homeDirectory: home
                    )
                },
                policy: policy,
                // The hook client's deadline (bound by `JudgeOffload`): an
                // evaluation it has given up on stops pattern search. Not
                // the judge deadline: a non-hook door's judge bound must not
                // turn its rule verdict indeterminate.
                patternBudget: PatternBudget(hardDeadline: JudgeOffload.hookDeadline)
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
        invocationDisplay: String? = nil,
        rawCommand: String? = nil
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
            invocationDisplay: invocationDisplay,
            rawCommand: rawCommand
        )
    }

    private static func workspaceURL(cwd: WorkingDirectory?) -> URL? {
        cwd.map { URL(fileURLWithPath: $0.rawValue, isDirectory: true) }
    }

    /// The audit row for a deny the Policy gate overrode; nil otherwise.
    /// `withDenial` is false when `HookDoor` will answer with the timeout
    /// deny instead (past the hook deadline, no grant spent): the row then
    /// carries no deny rows, as no deny row is written then.
    private static func overrideAudit(
        candidate: EvaluationResult,
        finished: EvaluationResult,
        override: PolicyOverride,
        host: LedgerHost,
        tool: LedgerTool,
        cwd: WorkingDirectory?,
        now: Date,
        withDenial: Bool
    ) -> GatedEffect? {
        guard case .deny(let deny) = candidate.decision, case .allow = finished.decision else { return nil }
        // The deny's rows for when the override row does not land. Built
        // whenever in time, so the override row itself is never skipped.
        let denial: GatedEffect.DenialRow?
        if withDenial == false {
            denial = nil
        } else if case .denialRow(let row)? = denialRow(for: candidate, path: nil, host: host, tool: tool, now: now) {
            denial = row
        } else {
            denial = GatedEffect.DenialRow(
                at: now, host: host, tool: tool, ruleID: deny.ruleID, category: .pack(deny.ruleID.pack), path: "",
                session: attributedSession())
        }
        let name: String
        switch override {
        case .none: return nil
        case .allowlist: name = "allowlist"
        case .allowOnce: name = "allowOnce"
        case .rebaseRecovery: name = "rebaseRecovery"
        case .containedReversible: name = "containedReversible"
        }
        return .overrideAudit(GatedEffect.OverrideRow(
            at: now, host: host, ruleID: deny.ruleID, override: name, workspace: workspaceURL(cwd: cwd),
            denial: denial
        ))
    }

    /// The denial row a final deny or an indeterminate refusal asks for;
    /// nil for an allow.
    private static func denialRow(
        for result: EvaluationResult,
        path: String?,
        host: LedgerHost,
        tool: LedgerTool,
        now: Date,
        observed: Bool = false,
        wouldBe: LedgerWouldBe = .deny
    ) -> GatedEffect? {
        if case .indeterminate(let reason) = result.outcome {
            let ruleID = indeterminateRuleID(reason)
            return .denialRow(GatedEffect.DenialRow(
                at: now, host: host, tool: tool, ruleID: ruleID, category: .pack(ruleID.pack), path: path ?? "",
                observed: observed, wouldBe: wouldBe, indeterminate: reason, session: attributedSession()
            ))
        }
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
            at: now, host: host, tool: tool, ruleID: deny.ruleID, category: category, path: rawPath,
            observed: observed, wouldBe: wouldBe, session: attributedSession()
        ))
    }

    /// The audit subject of an indeterminate refusal, in rule-id form:
    /// `rv.indeterminate:<reason>`, the stable `IndeterminateReason` raw
    /// value. Not a pack rule; no allowlist entry or grant ever applies.
    static func indeterminateRuleID(_ reason: IndeterminateReason) -> RuleID {
        RuleID(pack: PackID(rawValue: "rv.indeterminate"), pattern: reason.rawValue)
    }

    /// The bound hook request's session id, if it is an opaque token.
    /// Read on the task (task-local), never inside `JudgeOffload`.
    private static func attributedSession() -> String? {
        HookSessionAttribution.current.flatMap { DenialLedgerRecord.attributableSession($0.rawValue) }
    }

    /// The ledger's `would_be` for an enforce authorization.
    private static func ledgerWouldBe(_ authorization: HookAuthorization) -> LedgerWouldBe {
        authorization == .ask ? .ask : .deny
    }

    /// The exemption-drops row for one evaluation's dropped repo literals;
    /// nil when nothing was dropped.
    private static func exemptionAudit(_ dropped: [String], workspace: URL?, now: Date) -> GatedEffect? {
        guard dropped.isEmpty == false else { return nil }
        return .exemptionAudit(GatedEffect.ExemptionAudit(dropped: dropped, workspace: workspace, at: now))
    }

    /// The shell: applies one evaluation's effects in order. Missing home
    /// has no config directory, so nothing is written. Every door that
    /// applies (and so can emit an override row) runs in rvd, which does
    /// not start without a home (`RVDLaunch.requireHome`); the CLI's
    /// in-process route only peeks. The hook deadline
    /// is applied by the decision (no `.denialRow` is emitted past it);
    /// the exemption audit and judge log are not deadline-gated.
    /// Returns false when a `command.override` row did not land; the shell
    /// door then keeps the deny (only that door emits override rows).
    /// An override row and its fallback deny row share one `lockWait`, so
    /// a held lock costs the command one wait, not two. `lockWait` is a
    /// seam for tests.
    @discardableResult
    static func perform(
        _ effects: [GatedEffect], home: HomeDirectory?,
        lockWait: () -> AuditLog.LockWait = { AuditLog.LockWait(timeout: AuditLog.defaultLockTimeout) }
    ) -> Bool {
        guard let home else { return true }
        var overridesRecorded = true
        for effect in effects {
            switch effect {
            case .exemptionAudit(let audit):
                auditDroppedRepoLiterals(audit.dropped, home: home, workspace: audit.workspace, now: audit.at)
            case .judgeLog(let row):
                JudgeRuntime.appendLog(row, home: home)
            case .denialRow(let row):
                // Chained record first: a forward that runs between the two
                // writes then sees the chained row and drops the blocks copy.
                auditDenial(row, home: home)
                // The ledger is rule-oriented (`rv blocks`; the review queue
                // offers allow-once): an indeterminate refusal is neither.
                if row.indeterminate == nil { recordDenial(row, home: home) }
            case .overrideAudit(let row):
                let wait = lockWait()
                guard auditOverride(row, home: home, wait: wait) == false else { continue }
                overridesRecorded = false
                AuditDropLog.shared.report(
                    .commandOverride, file: auditFile(home),
                    consequence: "the override of \(row.ruleID.rawValue) was not applied and the command stays denied")
                // The deny the shell door now returns gets its own rows,
                // within what is left of the same lock wait; either may
                // fail too, which changes nothing.
                if let denial = row.denial {
                    auditDenial(denial, home: home, wait: wait)
                    recordDenial(denial, home: home)
                }
            }
        }
        return overridesRecorded
    }

    /// What `performBounded` could not write.
    struct BoundedRecord: Sendable, Equatable {
        /// Rows dropped (ledger, judge log, exemption audit; `.audit` only
        /// for an override row, which never reaches the evaluator).
        var drops: [HookLocalDrop] = []
        /// Audit rows that did not land, for rvd to append from the spool.
        var audits: [HookLocalSpool.Audit] = []
        /// An audit row did not land and `escalateUnrecordedDeny` was set:
        /// nothing else was written, and the caller must escalate.
        var unrecordedDeny = false
    }

    /// The hook-local evaluator's form of `perform`
    /// (docs/architecture/hook-local-decide.md, "Effects"): the same rows,
    /// all ending by one `deadline`, so logs another process holds (or a
    /// FIFO planted in their place) cost the verdict at most that long.
    ///
    /// The `audit.jsonl` rows go first, each with up to `auditFloor` of
    /// what is left. When one cannot land: with `escalateUnrecordedDeny`
    /// (enforce) the evaluator must not answer a deny whose chained record
    /// is missing, so this returns `unrecordedDeny` having written nothing
    /// else, and rvd re-evaluates and writes every row itself; without it
    /// (observe, where the C hook's step-aside could turn a floor deny into
    /// an allow, so escalating is never safer) the row's non-secret fields
    /// go to the spool for rvd to append. The other rows share what is
    /// left, in `perform`'s order; one past the deadline is dropped
    /// unwritten and named for the evaluator to count. An override row
    /// never reaches here (the evaluator escalates any pass that emits
    /// one); one that did would be dropped, since only rvd spends what an
    /// override needs.
    static func performBounded(
        _ effects: [GatedEffect],
        home: HomeDirectory,
        deadline: ContinuousClock.Instant,
        auditFloor: Duration,
        escalateUnrecordedDeny: Bool,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) -> BoundedRecord {
        var record = BoundedRecord()
        for case .denialRow(let row) in effects {
            let wait = AuditLog.LockWait(deadline: min(now() + auditFloor, deadline), now: now)
            guard auditDenial(row, home: home, wait: wait) == false else { continue }
            if escalateUnrecordedDeny { return BoundedRecord(unrecordedDeny: true) }
            record.audits.append(HookLocalSpool.Audit(row, home: home))
        }
        let wait = AuditLog.LockWait(deadline: deadline, now: now)
        for effect in effects {
            switch effect {
            case .exemptionAudit(let audit):
                if auditDroppedRepoLiterals(
                    audit.dropped, home: home, workspace: audit.workspace, now: audit.at, wait: wait) == false {
                    record.drops.append(.exemption)
                }
            case .judgeLog(let row):
                let remaining = wait.remaining ?? .zero
                if remaining <= .zero
                    || JudgeRuntime.appendLog(
                        row, home: home, lockTimeout: min(JudgeRuntime.logLockTimeout, remaining)) == false
                {
                    record.drops.append(.judgeLog)
                }
            case .denialRow(let row):
                if recordDenial(row, home: home, wait: wait) == false { record.drops.append(.denialLedger) }
            case .overrideAudit:
                record.drops.append(.audit)
            }
        }
        return record
    }

    /// Appends a `command.denied` event to the hash-chained `audit.jsonl`
    /// for every enforced deny (`command.observed`, decision `info`, for an
    /// observe-mode would-be deny), whatever `blocks.enabled` says: the
    /// ledger is a pruned convenience view, the chain is the record.
    /// Carries the rule, host, tool, redacted path and the hook session id
    /// (when an opaque token), never the command text. An indeterminate
    /// refusal is the same row marked `verdict: indeterminate`, its reason
    /// class in `reason`.
    @discardableResult
    private static func auditDenial(
        _ row: GatedEffect.DenialRow, home: HomeDirectory,
        wait: AuditLog.LockWait = AuditLog.LockWait(timeout: AuditLog.defaultLockTimeout)
    ) -> Bool {
        var detail = ["host": row.host.rawValue, "tool": row.tool.rawValue, "category": row.category.rawValue]
        let path = DenialPathRedaction.redact(row.path, home: home)
        if path.isEmpty == false { detail["path"] = path }
        if row.observed { detail["would_be"] = row.wouldBe.rawValue }
        if row.indeterminate != nil { detail["verdict"] = "indeterminate" }
        if let session = row.session { detail["session"] = session }
        let recorded = AuditLog.append(
            AuditEvent(
                time: row.at,
                kind: row.observed ? .commandObserved : .commandDenied,
                decision: row.observed ? .info : .denied,
                subject: row.ruleID.rawValue, reason: row.indeterminate?.rawValue,
                agent: row.host == .tty ? nil : row.host.rawValue,
                source: AuditLedger.Source.audit.rawValue, detail: detail
            ),
            configDirectory: RVPolicyPaths.configDirectory(home: home),
            wait: wait
        )
        // The verdict stands either way; say that its chained record is missing.
        if recorded == false {
            AuditDropLog.shared.report(
                row.observed ? .commandObserved : .commandDenied, file: auditFile(home),
                consequence: row.observed
                    ? "the observed allow under \(row.ruleID.rawValue) stands unrecorded"
                    : row.indeterminate == nil
                    ? "the deny by \(row.ruleID.rawValue) stands unrecorded"
                    : "the indeterminate refusal \(row.ruleID.rawValue) stands unrecorded")
        }
        return recorded
    }

    private static func auditFile(_ home: HomeDirectory) -> URL {
        AuditLog.fileURL(configDirectory: RVPolicyPaths.configDirectory(home: home))
    }

    /// Appends a `command.override` event: a deny a human-granted or policy
    /// override turned into an allow. The rule and override kind only.
    /// Returns whether the row landed.
    private static func auditOverride(
        _ row: GatedEffect.OverrideRow, home: HomeDirectory, wait: AuditLog.LockWait
    ) -> Bool {
        AuditLog.append(
            AuditEvent(
                time: row.at, kind: .commandOverride, decision: .allowed,
                subject: row.ruleID.rawValue, reason: row.override,
                workspace: row.workspace.map { DenialPathRedaction.redact($0.path, home: home) },
                agent: row.host == .tty ? nil : row.host.rawValue,
                source: AuditLedger.Source.audit.rawValue,
                detail: ["host": row.host.rawValue, "override": row.override]
            ),
            configDirectory: RVPolicyPaths.configDirectory(home: home),
            wait: wait
        )
    }

    /// Appends a denial row when the ledger is enabled (`blocks.enabled`,
    /// read here, deny-only). The path is redacted against home. With a
    /// `wait`, a held ledger lock is retried only until it passes; returns
    /// false when the row was dropped for that or the wait had already
    /// passed (true when it landed, the ledger is off, or no `wait` bounds
    /// it).
    @discardableResult
    private static func recordDenial(
        _ row: GatedEffect.DenialRow, home: HomeDirectory, wait: AuditLog.LockWait? = nil
    ) -> Bool {
        let configDir = RVPolicyPaths.configDirectory(home: home)
        guard DenialLedgerPreferences.isEnabled(inConfigDirectory: configDir) else { return true }
        let record = DenialLedgerRecord(
            timestamp: row.at,
            host: row.host,
            tool: row.tool,
            ruleID: row.ruleID,
            category: row.category,
            path: DenialPathRedaction.redact(row.path, home: home),
            observed: row.observed,
            wouldBe: row.wouldBe,
            session: row.session
        )
        let ledger = DenialLedger(configDirectory: configDir)
        if let wait, wait.expired { return false }
        guard let wait else {
            ledger.append(record, now: row.at)
            return true
        }
        return ledger.append(record, now: row.at, wait: wait)
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
    ///
    /// With a `wait`, a held lock is retried (non-blocking) only until it
    /// passes, and nothing is tried once it has. Returns false when the row
    /// was dropped for a lock or I/O failure or a passed wait, true when it
    /// landed or there was nothing to write.
    @discardableResult
    static func auditDroppedRepoLiterals(
        _ dropped: [String],
        home: HomeDirectory?,
        workspace: URL?,
        now: Date,
        wait: AuditLog.LockWait? = nil
    ) -> Bool {
        guard dropped.isEmpty == false, let home else { return true }
        if let wait, wait.expired { return false }
        let store = FileLockedJSONLStore<ExemptionDropRecord>(
            baseDirectory: RVPolicyPaths.configDirectory(home: home),
            fileName: exemptionDropsFileName
        )
        let write = { (nonBlocking: Bool) throws in
            try store.withLock(nonBlocking: nonBlocking) {
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
        guard let wait else { return (try? write(false)) != nil }
        let landed = wait.retrying { () -> Bool? in
            do {
                try write(true)
                return true
            } catch FileLockedJSONLStoreError.lockFailed {
                return nil
            } catch {
                return false
            }
        }
        return landed ?? false
    }
}

extension HookLocalSpool.Audit {
    /// The fields `GatedEvaluate.auditDenial` writes for `row`, never the
    /// command text: the path is redacted against home, as in the chain,
    /// and left out when empty or past `HookLocalSpool.maxPathBytes`.
    init(_ row: GatedEffect.DenialRow, home: HomeDirectory) {
        let path = DenialPathRedaction.redact(row.path, home: home)
        self.init(
            kind: (row.observed ? AuditEventKind.commandObserved : .commandDenied).rawValue,
            rule: row.ruleID.rawValue,
            host: row.host.rawValue,
            tool: row.tool.rawValue,
            category: row.category.rawValue,
            path: path.isEmpty || path.utf8.count > HookLocalSpool.maxPathBytes ? nil : path,
            wouldBe: row.observed ? row.wouldBe.rawValue : nil,
            at: row.at.timeIntervalSince1970)
    }
}
