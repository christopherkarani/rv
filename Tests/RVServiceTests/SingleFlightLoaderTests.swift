import Foundation
import Synchronization
import RVDomain
import Testing
@testable import RVService

@Suite("Single-flight judge loader")
struct SingleFlightLoaderTests {
    private let key = URL(fileURLWithPath: "/tmp/rv-judge-bundle")

    @Test func concurrentRequestsShareOneLoad() async {
        let loader = SingleFlightLoader<Box>()
        let makes = Counter()
        let gate = DispatchSemaphore(value: 0)
        let key = self.key
        let outcomes = await withTaskGroup(of: Box?.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    // `value` blocks its caller until the load lands. Call it
                    // off the cooperative pool, as rvd does: six blocked pool
                    // threads would starve the release below (and every other
                    // test in the process) on a small CI runner.
                    let outcome = await JudgeOffload.run {
                        loader.value(key: key, stamp: 1, wait: .seconds(10)) {
                            makes.hit()
                            gate.wait()
                            return Box(id: 7)
                        }
                    }
                    if case .ready(let box) = outcome { return box }
                    return nil
                }
            }
            // Let every request join before the one load finishes.
            try? await Task.sleep(for: .milliseconds(300))
            gate.signal()
            var collected: [Box?] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }
        #expect(makes.count == 1)
        #expect(outcomes.count == 6)
        #expect(outcomes.allSatisfy { $0?.id == 7 })
        #expect(Set(outcomes.compactMap { $0.map(ObjectIdentifier.init) }).count == 1)
    }

    @Test func waitIsBoundedWhileTheLoadIsStillWarming() {
        let loader = SingleFlightLoader<Box>()
        let makes = Counter()
        let gate = DispatchSemaphore(value: 0)
        let started = ContinuousClock.now
        let outcome = loader.value(key: key, stamp: 1, wait: .milliseconds(150)) {
            makes.hit()
            gate.wait()
            return Box(id: 1)
        }
        let waited = ContinuousClock.now - started
        guard case .warming = outcome else {
            Issue.record("a load past the deadline must report warming, got \(outcome)")
            gate.signal()
            return
        }
        #expect(waited < .seconds(2))

        // The load keeps going in the background; once it lands, the
        // next request is served from cache with no second load.
        gate.signal()
        let ready = loader.value(key: key, stamp: 1, wait: .seconds(10)) {
            makes.hit()
            return Box(id: 2)
        }
        guard case .ready(let box) = ready else {
            Issue.record("finished load must be ready, got \(ready)")
            return
        }
        #expect(box.id == 1)
        #expect(makes.count == 1)
    }

    @Test func prewarmStartsWithoutBlockingAndRequestsJoinIt() {
        let loader = SingleFlightLoader<Box>()
        let makes = Counter()
        let gate = DispatchSemaphore(value: 0)
        let started = ContinuousClock.now
        loader.prewarm(key: key, stamp: 1) {
            makes.hit()
            gate.wait()
            return Box(id: 3)
        }
        #expect(ContinuousClock.now - started < .milliseconds(500))
        let warming = loader.value(key: key, stamp: 1, wait: .milliseconds(50)) {
            makes.hit()
            return Box(id: 99)
        }
        guard case .warming = warming else {
            Issue.record("request during prewarm must join it, got \(warming)")
            gate.signal()
            return
        }
        gate.signal()
        let ready = loader.value(key: key, stamp: 1, wait: .seconds(10)) {
            makes.hit()
            return Box(id: 99)
        }
        guard case .ready(let box) = ready else {
            Issue.record("prewarmed load must be ready, got \(ready)")
            return
        }
        #expect(box.id == 3)
        #expect(makes.count == 1)
    }

    @Test func failedLoadIsCachedPerStampAndRetriedAfterRepair() {
        let loader = SingleFlightLoader<Box>()
        let makes = Counter()
        let first = loader.value(key: key, stamp: 1, wait: nil) {
            makes.hit()
            throw Broken()
        }
        guard case .failed(let error) = first else {
            Issue.record("first failed load must surface its error, got \(first)")
            return
        }
        #expect(error is Broken)

        let cached = loader.value(key: key, stamp: 1, wait: nil) {
            makes.hit()
            return Box(id: 5)
        }
        guard case .cachedFailure = cached else {
            Issue.record("same-stamp retry must hit the cached failure, got \(cached)")
            return
        }
        #expect(makes.count == 1)

        let repaired = loader.value(key: key, stamp: 2, wait: nil) {
            makes.hit()
            return Box(id: 5)
        }
        guard case .ready(let box) = repaired else {
            Issue.record("a repaired bundle must reload, got \(repaired)")
            return
        }
        #expect(box.id == 5)
        #expect(makes.count == 2)
    }

    @Test func cachedFailureExpiresSoATransientFailureRetries() {
        let clock = ManualInstant()
        let loader = SingleFlightLoader<Box>(retryFailuresAfter: .seconds(60), now: { clock.now })
        let makes = Counter()
        _ = loader.value(key: key, stamp: 1, wait: nil) {
            makes.hit()
            throw Broken()
        }
        clock.advance(.seconds(30))
        let cached = loader.value(key: key, stamp: 1, wait: nil) {
            makes.hit()
            return Box(id: 8)
        }
        guard case .cachedFailure = cached else {
            Issue.record("inside the retry window the failure stays cached, got \(cached)")
            return
        }
        #expect(makes.count == 1)

        // Same stamp (model unchanged), but e.g. memory pressure has passed.
        clock.advance(.seconds(31))
        let retried = loader.value(key: key, stamp: 1, wait: nil) {
            makes.hit()
            return Box(id: 8)
        }
        guard case .ready(let box) = retried else {
            Issue.record("an expired negative cache must retry the load, got \(retried)")
            return
        }
        #expect(box.id == 8)
        #expect(makes.count == 2)
    }

    @Test func defaultFailureRetryIsAMinute() {
        #expect(SingleFlightLoader<Box>.defaultFailureRetry == .seconds(60))
    }

    @Test func anotherBundleReloads() {
        let loader = SingleFlightLoader<Box>()
        _ = loader.value(key: key, stamp: 1, wait: nil) { Box(id: 1) }
        let other = loader.value(key: URL(fileURLWithPath: "/tmp/other"), stamp: 1, wait: nil) {
            Box(id: 2)
        }
        guard case .ready(let box) = other else {
            Issue.record("a different bundle must load, got \(other)")
            return
        }
        #expect(box.id == 2)
    }
}

@Suite("Judge warming fails to human review")
struct JudgeWarmingOutcomeTests {
    @Test func warmingRaisesReviewNeverAllow() {
        let allow = EvaluationResult(
            outcome: .plain, matchingView: "npm install left-pad", analysis: .unknown)
        let (raised, note) = JudgeRuntime.warmingOutcomeSeam(over: allow)
        #expect(HookAuthorization.isPinned(raised) == false)
        guard case .deny(let deny) = raised.decision else {
            Issue.record("a warming judge must not allow, got \(raised.decision)")
            return
        }
        #expect(deny.ruleID.rawValue == "core.judge:laya-review")
        #expect(raised.boundReview == nil)
        #expect(note == "judge-warming")
    }
}

private final class Box: Sendable {
    let id: Int
    init(id: Int) { self.id = id }
}

private struct Broken: Error {}

private final class ManualInstant: Sendable {
    private let box = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { box.withLock { $0 } }
    func advance(_ by: Duration) { box.withLock { $0 = $0.advanced(by: by) } }
}

private final class Counter: Sendable {
    private let box = Mutex(0)
    var count: Int { box.withLock { $0 } }
    func hit() { box.withLock { $0 += 1 } }
}
