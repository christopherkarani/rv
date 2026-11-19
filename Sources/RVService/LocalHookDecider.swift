import Foundation
import RVDomain
import RVHistory
import RVHooks
import RVIPC
import RVPolicy

/// Why the hook-local evaluator handed a call to rvd instead of answering.
///
/// Every case is a reason rvd, and only rvd, can answer: it holds the judge
/// model, the allow-once grants, the unlock codes it issued and the pending
/// approvals. The wire names travel to the C hook on the escalate line.
package enum LocalHookEscalation: String, Sendable, CaseIterable {
    /// The judge would score this call. Phase 2b: the hook may ask the
    /// judge pool directly for exactly this class of call.
    case judge
    /// A deny the Policy gate may still turn into an allow (an allow-once
    /// grant, the allowlist, rebase recovery, a contained delete), or that
    /// a human may unlock.
    case policyGate = "policy-gate"
    /// A human-approvable deny: rvd mints the unlock code and records the
    /// pending row.
    case ask
    /// An unfinished evaluation. rvd renders it; nothing is decided here.
    case indeterminate
    /// The host payload did not decode.
    case malformed
    /// Observe mode, where the enforce verdict for the same call would not
    /// also be this allow (rvd's launch environment may pin enforce).
    case observe
    /// Anything this evaluator did not expect.
    case unexpected
}

/// The hook-local verdict: the exact host reply rvd would send, or a reason
/// to ask rvd.
package enum LocalHookOutcome: Sendable, Equatable {
    case final(HookEvaluateReply)
    case escalate(LocalHookEscalation)
}

/// Decides a hook call in the hook's own process when the answer cannot
/// depend on anything only rvd holds (docs/architecture/hook-local-decide.md).
///
/// It runs the door rvd runs (`hookWire` over `GatedEvaluate`'s decision
/// half) with probe ports in place of rvd's memory: an empty grant table,
/// a judge that records being asked, an allowlist loader that records the
/// Policy gate being consulted, and mint / pending ports that record an
/// ask. Any probe that fires escalates. A final answer is only:
///
/// - an allow no probe touched (no judge, no Policy gate), or
/// - a deny the Policy gate never sees (`policyGateAccess == .skip`) that
///   no human transport may unlock (`denyPinned`), or a file-tool deny
///   (the file door has no Policy gate, unlock code or pending row).
///
/// Under observe a final allow also needs the enforce verdict for the
/// same call to be that allow, so rvd answers it the same whatever its
/// launch environment pins.
package struct LocalHookDecider: Sendable {
    private let home: HomeDirectory
    private let clock: @Sendable () -> Date
    private let session: @Sendable () -> EvaluateSession

    package init(
        home: HomeDirectory,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(home: home, clock: clock, session: {
            EvaluationWorld.makeSession(
                coverage: EvaluationWorld.coverage(catalog: nil, home: home),
                snapshots: nil
            )
        })
    }

    /// `session` builds the Evaluate session (tests pass a prepared one).
    init(
        home: HomeDirectory,
        clock: @escaping @Sendable () -> Date,
        session: @escaping @Sendable () -> EvaluateSession
    ) {
        self.home = home
        self.clock = clock
        self.session = session
    }

    /// The local verdict for one hook call. A final verdict's writes (judge
    /// log, audit and denial rows, exemption audit) are done before it
    /// returns, exactly as rvd does them before it replies; an escalation
    /// writes nothing, so rvd's own evaluation writes each row once.
    package func decide(host: HookHost, stdin: String) async -> LocalHookOutcome {
        let codec = productionHostCodec(host)
        switch codec.decode(stdin) {
        case .malformed:
            return .escalate(.malformed)
        case .foreign:
            // rvd answers a call that is not this host's tool with the same
            // allow, before any evaluation.
            return .final(Self.reply(codec.encodeAllow()))
        case .request:
            break
        }
        let built = session()
        let now = clock()
        let ledger = LedgerHost.hook(host)
        let mode = JudgeRuntime.effectiveGuardMode(
            home: home, host: ledger, environment: [:], config: GuardConfig.read(home: home))
        let live = await run(host: host, stdin: stdin, session: built, now: now, environment: [:])
        guard case .final = live.outcome else { return live.outcome }
        if mode == .observe {
            // The enforce verdict for the same call, written nowhere.
            let enforced = await run(
                host: host, stdin: stdin, session: built, now: now,
                environment: ["RV_GUARD_MODE": GuardMode.enforce.rawValue])
            guard enforced.outcome == live.outcome else { return .escalate(.observe) }
        }
        GatedEvaluate.perform(live.effects, home: home)
        return live.outcome
    }

    private struct Run {
        let outcome: LocalHookOutcome
        let effects: [GatedEffect]
    }

    /// One pass of rvd's hook door with probe ports. `environment` stands
    /// in for rvd's launch environment: empty, or an enforce pin.
    private func run(
        host: HookHost,
        stdin: String,
        session: EvaluateSession,
        now: Date,
        environment: [String: String]
    ) async -> Run {
        let probe = LocalHookProbe()
        let gated = GatedEvaluate(session, judge: probe)
        let home = self.home
        let ledger = LedgerHost.hook(host)
        let world = HookEvaluateWorld(
            evaluate: { command, cwd in
                let decided = await gated.decideVerdict(
                    .apply,
                    GatedEvaluate.makeRequest(command: command, home: home),
                    cwd: cwd,
                    home: home,
                    // rvd's grants live in rvd. An empty table here is only
                    // sound because a consulted Policy gate escalates.
                    grants: EphemeralAllowOnceTable(),
                    now: now,
                    allowlist: {
                        probe.escalate(.policyGate)
                        return .empty
                    },
                    host: ledger,
                    tool: .bash,
                    previewsWouldBe: false,
                    inputs: EvaluationInputs.gather(
                        home: home, cwd: cwd, environment: environment, host: ledger)
                )
                probe.record(.shell(decided.result, cwd: cwd), effects: decided.effects)
                return decided.result
            },
            evaluateFile: { action, cwd in
                let decided = gated.decideFile(
                    action, home: home, cwd: cwd, host: ledger, now: now,
                    guardMode: JudgeRuntime.effectiveGuardMode(
                        home: home, host: ledger, environment: environment,
                        config: GuardConfig.read(home: home))
                )
                probe.record(.file(decided.result), effects: decided.effects)
                return decided.result
            },
            mintOnDeny: { _, _ in
                probe.escalate(.ask)
                return nil
            },
            recordHostAsk: { _, _ in
                probe.escalate(.ask)
            },
            mintOnDenyWithCommand: { _, _, _ in
                probe.escalate(.ask)
                return nil
            }
        )
        let wire = await hookWire(host: host, stdin: stdin, world: world)
        let classified = probe.classify(Self.reply(wire))
        return Run(outcome: classified.outcome, effects: classified.effects)
    }

    /// The reply rvd builds from a wire (`HookDoor`).
    private static func reply(_ wire: HookWire) -> HookEvaluateReply {
        HookEvaluateReply(stdout: wire.stdout, exitCode: wire.exitCode, stderr: wire.stderr)
    }
}

/// The ports that stand in for rvd's memory during one local pass. Each
/// records whether rvd would have been needed; `classify` turns that and
/// the evaluated result into the outcome.
private final class LocalHookProbe: JudgePort, Sendable {
    enum Door: Sendable {
        case shell(EvaluationResult, cwd: WorkingDirectory?)
        case file(EvaluationResult)
    }

    private struct State: Sendable {
        var escalation: LocalHookEscalation?
        var door: Door?
        var effects: [GatedEffect] = []
    }

    private let state = UnfairLock(State())

    func escalate(_ reason: LocalHookEscalation) {
        state.withLock { state in
            if state.escalation == nil { state.escalation = reason }
        }
    }

    func record(_ door: Door, effects: [GatedEffect]) {
        state.withLock { state in
            // One evaluation per hook call; a second is not rvd's door.
            if state.door != nil { state.escalation = state.escalation ?? .unexpected }
            state.door = door
            state.effects = effects
        }
    }

    /// The judge would run: rvd scores this one. The run itself is never
    /// read, as the pass escalates.
    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        escalate(.judge)
        return .busy
    }

    func classify(_ reply: HookEvaluateReply) -> (outcome: LocalHookOutcome, effects: [GatedEffect]) {
        let (escalation, door, effects) = state.withLock { ($0.escalation, $0.door, $0.effects) }
        if let escalation { return (.escalate(escalation), []) }
        // A decoded request that reached no evaluation (an empty file path)
        // is rvd's to render.
        guard let door else { return (.escalate(.unexpected), []) }
        // Only rvd may write an override row, and only after spending
        // something; a consulted Policy gate has escalated already.
        if effects.contains(where: { if case .overrideAudit = $0 { true } else { false } }) {
            return (.escalate(.unexpected), [])
        }
        switch door {
        case .shell(let result, let cwd):
            switch result.decision {
            case .allow:
                return (.final(reply), effects)
            case .indeterminate:
                return (.escalate(.indeterminate), [])
            case .deny:
                guard HookAuthorization.policyGateAccess(for: result) == .skip else {
                    return (.escalate(.policyGate), [])
                }
                guard HookAuthorization.project(result: result, cwd: cwd) == .denyPinned else {
                    return (.escalate(.ask), [])
                }
                return (.final(reply), effects)
            }
        case .file(let result):
            switch result.decision {
            case .allow, .deny:
                return (.final(reply), effects)
            case .indeterminate:
                return (.escalate(.indeterminate), [])
            }
        }
    }
}
