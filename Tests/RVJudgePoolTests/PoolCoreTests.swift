import Foundation
import Testing
@testable import RVJudgePool

/// Drives `PoolCore` with a hand-held clock: no processes, no waiting.
struct PoolHarness {
    static let key = ModelKey(engine: "ft", bundle: "/models/laya-ft-v2-coreml")
    static let input = JudgeInput(command: "rm -rf build", contextLines: ["cwd-inside-repo: yes"])

    var core: PoolCore
    let start = ContinuousClock.now
    var now: ContinuousClock.Instant
    /// Generation of the live process per slot, as the spawns named them.
    var generation: [WorkerSlot: UInt64] = [:]

    init(policy: PoolPolicy = .live) {
        core = PoolCore(policy: policy)
        now = start
    }

    mutating func at(_ milliseconds: Int) {
        now = start + .milliseconds(milliseconds)
    }

    @discardableResult
    mutating func handle(_ event: PoolEvent) -> [PoolEffect] {
        let effects = core.handle(event, now: now)
        for case .spawn(let slot, let g, _) in effects { generation[slot] = g }
        return effects
    }

    @discardableResult
    mutating func tick() -> [PoolEffect] { handle(.tick) }

    @discardableResult
    mutating func ready(_ slot: WorkerSlot) -> [PoolEffect] {
        handle(.worker(slot, generation: generation[slot]!, .ready(checkpoint: "laya-ft-v2-fp16")))
    }

    @discardableResult
    mutating func verdict(_ slot: WorkerSlot, _ id: String, _ body: String = "{}") -> [PoolEffect] {
        handle(.worker(slot, generation: generation[slot]!, .verdict(id: id, verdict: Data(body.utf8))))
    }

    @discardableResult
    mutating func failed(_ slot: WorkerSlot, _ id: String) -> [PoolEffect] {
        handle(.worker(slot, generation: generation[slot]!, .failed(id: id)))
    }

    @discardableResult
    mutating func exited(_ slot: WorkerSlot) -> [PoolEffect] {
        handle(.exited(slot, generation: generation[slot]!))
    }

    @discardableResult
    mutating func submit(_ id: String, budget: Duration = .seconds(8)) -> [PoolEffect] {
        handle(.submit(id: id, key: Self.key, input: Self.input, budget: budget))
    }

    /// Both workers spawned and loaded, the primary first.
    mutating func warmBoth() {
        let first = handle(.warm(Self.key))
        precondition(first.spawns == [.primary])
        let second = ready(.primary)
        precondition(second.spawns == [.hedge])
        ready(.hedge)
    }
}

extension [PoolEffect] {
    var spawns: [WorkerSlot] {
        compactMap { if case .spawn(let slot, _, _) = $0 { slot } else { nil } }
    }

    var sends: [WorkerSlot: String] {
        var out: [WorkerSlot: String] = [:]
        for case .send(let slot, _, let request) in self { out[slot] = request.id }
        return out
    }

    var kills: [WorkerSlot] {
        compactMap { if case .kill(let slot, _) = $0 { slot } else { nil } }
    }

    func reply(_ id: String) -> PoolOutcome? {
        for case .reply(let rid, let outcome) in self where rid == id { return outcome }
        return nil
    }
}

@Suite("PoolCore — routing, hedge, kill, respawn")
struct PoolCoreTests {
    @Test("warm spawns the primary first, the hedge only after it loads")
    func loadsOneAtATime() {
        var pool = PoolHarness()
        #expect(pool.handle(.warm(PoolHarness.key)).spawns == [.primary])
        #expect(pool.tick().spawns.isEmpty, "never two loads at once")
        #expect(pool.ready(.primary).spawns == [.hedge])
        pool.ready(.hedge)
        let status = pool.core.status()
        #expect(status.workers.map(\.phase) == ["ready", "ready"])
        #expect(status.routing == "hedged")
    }

    @Test("the default pool runs CPU as the primary and the GPU only as the hedge")
    func defaultComputeRoles() {
        #expect(PoolPolicy.live.primaryCompute == .cpu)
        #expect(PoolPolicy.live.hedgeCompute == .accelerated)
        var pool = PoolHarness()
        pool.warmBoth()
        let workers = pool.core.status().workers
        #expect(workers.map(\.slot) == [.primary, .hedge])
        #expect(workers.map(\.compute) == ["cpu", "accelerated"])
        let swapped = PoolCore(policy: PoolPolicy(primaryCompute: .accelerated, hedgeCompute: .cpu)).status()
        #expect(swapped.workers.map(\.compute) == ["accelerated", "cpu"])
    }

    @Test("a busy primary: the next request waits primaryBusyWait for it, then goes to the hedge")
    func busyPrimaryWaitsThenHedge() {
        var pool = PoolHarness()
        pool.warmBoth()
        #expect(pool.submit("a").sends == [.primary: "a"])
        #expect(pool.submit("b").sends.isEmpty, "the primary is only busy: wait for it")
        #expect(pool.core.nextWake(after: pool.now) == pool.start + .milliseconds(40))
        pool.at(39)
        #expect(pool.tick().sends.isEmpty)
        pool.at(40)
        #expect(pool.tick().sends == [.hedge: "b"])
    }

    @Test("a busy primary that frees up within the wait takes the next request itself")
    func busyPrimaryFreesInTime() {
        var pool = PoolHarness()
        pool.warmBoth()
        pool.submit("a")
        pool.submit("b")
        pool.at(20)
        #expect(pool.verdict(.primary, "a").sends == [.primary: "b"])
        #expect(pool.core.status().hedged == 0)
    }

    @Test("a primary that is down or degraded sends requests to the hedge at once")
    func downPrimaryNoWait() {
        var pool = PoolHarness()
        pool.warmBoth()
        pool.exited(.primary)
        #expect(pool.submit("a").sends == [.hedge: "a"])
    }

    @Test("a request goes to the primary and its verdict is the answer")
    func primaryAnswers() {
        var pool = PoolHarness()
        pool.warmBoth()
        #expect(pool.submit("r1").sends == [.primary: "r1"])
        pool.at(300)
        let effects = pool.verdict(.primary, "r1", #"{"choice":"allow"}"#)
        #expect(effects.reply("r1") == .verdict(Data(#"{"choice":"allow"}"#.utf8), slot: .primary))
        #expect(pool.core.status().served == 1)
    }

    @Test("no answer after hedgeAfter: the hedge gets it too and the first verdict wins")
    func hedges() {
        var pool = PoolHarness()
        pool.warmBoth()
        pool.submit("r1")
        pool.at(149)
        #expect(pool.tick().sends.isEmpty)
        pool.at(150)
        #expect(pool.tick().sends == [.hedge: "r1"])
        pool.at(900)
        #expect(pool.verdict(.hedge, "r1").reply("r1") == .verdict(Data("{}".utf8), slot: .hedge))
        // The primary's late answer is dropped; it is free again.
        pool.at(1000)
        #expect(pool.verdict(.primary, "r1").reply("r1") == nil)
        let status = pool.core.status()
        #expect(status.hedged == 1)
        #expect(status.hedgeWins == 1)
        #expect(status.workers.allSatisfy { $0.phase == "ready" })
    }

    @Test("a worker still busy at the budget is SIGKILLed, the request answers late, the worker respawns")
    func killsOverrun() {
        var pool = PoolHarness()
        pool.warmBoth()
        pool.submit("r1")
        pool.at(450)
        pool.tick() // hedged
        pool.at(1500)
        let effects = pool.tick()
        #expect(effects.reply("r1") == .late)
        #expect(effects.kills == [.primary], "the hedge got it at 450 ms, so its own budget runs to 1950 ms")
        // Backoff before the respawn: a kill is a fault.
        #expect(pool.exited(.primary).spawns.isEmpty)
        pool.at(1750)
        #expect(pool.tick().spawns == [.primary])
        pool.at(1950)
        #expect(pool.tick().kills == [.hedge])
        #expect(pool.core.status().killed == 2)
    }

    @Test("the kill uses the full budget even when the client's deadline is shorter")
    func shortClientDeadlineDoesNotKill() {
        var pool = PoolHarness()
        pool.warmBoth()
        pool.submit("r1", budget: .milliseconds(300))
        pool.at(300)
        let effects = pool.tick()
        #expect(effects.reply("r1") == .late)
        #expect(effects.kills.isEmpty, "a short request deadline must not cost a worker")
        pool.at(500)
        #expect(pool.verdict(.primary, "r1").reply("r1") == nil)
        #expect(pool.core.status().workers[0].phase == "ready")
    }

    @Test("a worker crash mid-request moves the request to the other worker at once")
    func crashRoutes() {
        var pool = PoolHarness()
        pool.warmBoth()
        pool.submit("r1")
        pool.at(100)
        let effects = pool.exited(.primary)
        #expect(effects.sends == [.hedge: "r1"])
        pool.at(349)
        #expect(pool.tick().spawns.isEmpty)
        pool.at(350)
        #expect(pool.tick().spawns == [.primary], "respawned after the first backoff step")
        pool.at(400)
        #expect(pool.verdict(.hedge, "r1").reply("r1") == .verdict(Data("{}".utf8), slot: .hedge))
    }

    @Test("repeated primary faults degrade it: everything routes to the hedge")
    func degradesPrimary() {
        var pool = PoolHarness()
        pool.warmBoth()
        var clock = 0
        for _ in 0..<3 {
            pool.exited(.primary)
            clock += 40_000
            pool.at(clock)
            let effects = pool.tick()
            if pool.core.status().workers[0].degraded {
                #expect(effects.spawns.isEmpty)
                break
            }
            #expect(effects.spawns == [.primary])
            pool.ready(.primary)
        }
        let status = pool.core.status()
        #expect(status.workers[0].degraded)
        #expect(status.routing == "hedge only (primary degraded)")
        #expect(pool.submit("r1").sends == [.hedge: "r1"])
        // Cooldown over: the primary comes back.
        pool.at(clock + 600_000)
        #expect(pool.tick().spawns == [.primary])
        #expect(!pool.core.status().workers[0].degraded)
    }

    @Test("faults spread wider than the window do not degrade")
    func spreadFaultsDoNotDegrade() {
        var pool = PoolHarness()
        pool.warmBoth()
        var clock = 0
        for _ in 0..<5 {
            pool.exited(.primary)
            clock += 200_000
            pool.at(clock)
            #expect(pool.tick().spawns == [.primary])
            pool.ready(.primary)
        }
        #expect(!pool.core.status().workers[0].degraded)
    }

    @Test("both workers degraded fails closed at once")
    func bothDegraded() {
        var pool = PoolHarness(policy: PoolPolicy(faultsToDegrade: 1))
        pool.warmBoth()
        pool.exited(.primary)
        pool.exited(.hedge)
        #expect(pool.submit("r1").reply("r1") == .failed("judge workers are crash-looping"))
        #expect(pool.core.status().routing == "none (both workers degraded)")
    }

    @Test("the queue is bounded: one past the limit is busy at once")
    func boundedQueue() {
        var pool = PoolHarness(policy: PoolPolicy(primaryBusyWait: .zero, queueLimit: 2))
        pool.warmBoth()
        pool.submit("a") // primary
        pool.submit("b") // hedge
        #expect(pool.submit("c").reply("c") == nil)
        #expect(pool.submit("d").reply("d") == nil)
        #expect(pool.submit("e").reply("e") == .busy)
        #expect(pool.core.status().refusedBusy == 1)
        // The primary frees up: the head of the queue runs next, in order.
        pool.at(200)
        #expect(pool.verdict(.primary, "a").sends == [.primary: "c"])
    }

    @Test("a prediction failure moves to the other worker; failing on both fails closed")
    func predictionFailure() {
        var pool = PoolHarness()
        pool.warmBoth()
        pool.submit("r1")
        #expect(pool.failed(.primary, "r1").sends == [.hedge: "r1"])
        #expect(pool.failed(.hedge, "r1").reply("r1") == .failed("judge prediction failed"))
    }

    @Test("no worker loaded within the budget answers warming")
    func warming() {
        var pool = PoolHarness()
        pool.submit("r1")
        pool.at(1500)
        #expect(pool.tick().reply("r1") == .warming)
    }

    @Test("both workers report the bundle unloadable: broken install, until the retry")
    func loadFailure() {
        var pool = PoolHarness()
        let failure = LoadFailure(kind: .badBundle, message: "tokenizer.json missing")
        pool.submit("r1")
        let afterA = pool.handle(.worker(.primary, generation: pool.generation[.primary]!, .loadFailed(failure)))
            + pool.exited(.primary)
        #expect(afterA.spawns == [.hedge], "the hedge still gets its own try")
        #expect(afterA.reply("r1") == nil)
        let afterB = pool.handle(.worker(.hedge, generation: pool.generation[.hedge]!, .loadFailed(failure)))
            + pool.exited(.hedge)
        #expect(afterB.reply("r1") == .loadFailed(failure))
        #expect(pool.submit("r2").reply("r2") == .loadFailed(failure))
        pool.at(60_000)
        #expect(pool.tick().spawns == [.primary], "retried after loadFailureRetry")
    }

    @Test("a primary that cannot load leaves the hedge serving")
    func primaryLoadFailureOnly() {
        var pool = PoolHarness()
        pool.handle(.warm(PoolHarness.key))
        pool.handle(.worker(.primary, generation: pool.generation[.primary]!,
                            .loadFailed(LoadFailure(kind: .modelUnavailable, message: "load failed"))))
        pool.exited(.primary)
        pool.ready(.hedge)
        #expect(pool.submit("r1").sends == [.hedge: "r1"])
    }

    @Test("a new model key restarts both workers and answers older requests warming")
    func keyChange() {
        var pool = PoolHarness()
        pool.warmBoth()
        pool.submit("r1")
        let other = ModelKey(engine: "laya", bundle: "/models/laya-multilingual-coreml")
        let effects = pool.handle(.submit(id: "r2", key: other, input: PoolHarness.input, budget: .seconds(8)))
        #expect(effects.reply("r1") == .warming)
        #expect(Set(effects.kills) == [.primary, .hedge])
        #expect(pool.exited(.primary).spawns == [.primary], "a restart for a new key is not a fault")
        #expect(pool.exited(.hedge).spawns.isEmpty, "one load at a time")
        #expect(pool.core.key == other)
    }

    @Test("a key change does not launder a degraded worker back into rotation")
    func keyChangeKeepsDegradation() {
        var pool = PoolHarness(policy: PoolPolicy(faultsToDegrade: 1))
        pool.warmBoth()
        pool.exited(.primary)
        #expect(pool.core.status().workers[0].degraded)
        let other = ModelKey(engine: "laya", bundle: "/models/laya-multilingual-coreml")
        let effects = pool.handle(.warm(other))
        #expect(effects.kills == [.hedge])
        #expect(pool.exited(.hedge).spawns == [.hedge], "only the healthy worker reloads")
        let status = pool.core.status()
        #expect(status.workers[0].degraded)
        #expect(status.routing == "hedge only (primary degraded)")
    }

    @Test("a second key change inside keyChangeInterval is refused; warm ignores it")
    func keyChangeRateLimited() {
        var pool = PoolHarness()
        pool.warmBoth()
        let second = ModelKey(engine: "laya", bundle: "/models/laya-multilingual-coreml")
        pool.at(1_000)
        pool.handle(.warm(second))
        #expect(pool.core.key == second)
        pool.at(5_000)
        let refused = pool.submit("r1")
        #expect(refused.reply("r1") == .failed("judge model changed too recently"))
        #expect(refused.kills.isEmpty)
        #expect(pool.handle(.warm(PoolHarness.key)).kills.isEmpty)
        #expect(pool.core.key == second)
        pool.at(11_000)
        pool.handle(.warm(PoolHarness.key))
        #expect(pool.core.key == PoolHarness.key, "allowed once the interval has passed")
    }

    @Test("the first key is adopted at once, with no interval")
    func firstKeyNotRateLimited() {
        var pool = PoolHarness()
        pool.handle(.warm(ModelKey(engine: "laya", bundle: "/models/laya-multilingual-coreml")))
        pool.at(100)
        pool.handle(.warm(PoolHarness.key))
        #expect(pool.core.key == PoolHarness.key, "warm before any change is not a change")
    }

    @Test("a worker that answers what it was not asked is killed as a fault")
    func outOfProtocol() {
        var pool = PoolHarness()
        pool.warmBoth()
        pool.submit("r1")
        let effects = pool.verdict(.primary, "other")
        #expect(effects.kills == [.primary])
        #expect(effects.sends == [.hedge: "r1"], "its request moves on")
    }

    @Test("malformed keys and spent budgets are refused without a worker")
    func refusals() {
        var pool = PoolHarness()
        pool.warmBoth()
        let bad = ModelKey(engine: "ft", bundle: "relative/path")
        #expect(pool.handle(.submit(id: "x", key: bad, input: PoolHarness.input, budget: .seconds(1)))
            .reply("x") == .failed("malformed judge request"))
        #expect(pool.submit("y", budget: .zero).reply("y") == .late)
    }

    @Test("a load that never finishes is killed at loadTimeout")
    func loadTimeout() {
        var pool = PoolHarness()
        pool.handle(.warm(PoolHarness.key))
        pool.at(180_000)
        #expect(pool.tick().kills == [.primary])
    }

    @Test("events from an older process of a slot are ignored")
    func staleGeneration() {
        var pool = PoolHarness()
        pool.warmBoth()
        let old = pool.generation[.primary]!
        pool.exited(.primary)
        pool.at(250)
        pool.tick()
        #expect(pool.handle(.worker(.primary, generation: old, .ready(checkpoint: "x"))).isEmpty)
        #expect(pool.core.status().workers[0].phase == "loading")
    }

    @Test("nextWake is always strictly in the future")
    func nextWakeNeverSpins() {
        var pool = PoolHarness()
        pool.warmBoth()
        pool.submit("a")
        pool.submit("b")
        pool.submit("c")
        for ms in stride(from: 0, through: 2000, by: 50) {
            pool.at(ms)
            pool.tick()
            if let wake = pool.core.nextWake(after: pool.now) {
                #expect(wake > pool.now)
            }
        }
    }
}
