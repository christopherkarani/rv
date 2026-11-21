import Dispatch
import Foundation
import Synchronization
import Testing
@testable import RVService
import RVDomain

/// A pack deny (self-protection, `git reset --hard`, `rm -rf ~`) does not
/// wait behind admitted judge calls: it is final before the judge is asked,
/// and the offload queue still gives it a thread while every admitted judge
/// call is stuck on the model. Not covered: model-load waits are not
/// admitted (JudgeGate's single-flight load), so a burst during a cold
/// load can still delay a deny by up to the 5 s load wait.
@Suite("Pack denies do not wait behind admitted judge calls")
struct JudgeDenyBypassTests {
    static let denies: [(pack: PackID, pattern: String, command: String)] = [
        (.coreSecrets, "home-rv-config", "rm ~/.config/rv/config.json"),
        (.coreGit, "reset-hard", "git reset --hard"),
    ]

    @Test("apply never calls the judge for a pack deny", arguments: 0..<denies.count)
    func packDenyNeverReachesTheJudge(_ index: Int) throws {
        let (pack, pattern, command) = Self.denies[index]
        let judge = CountingJudge()
        try withEmptyHome { home in
            let applied = Self.apply(deny(pack: pack, pattern: pattern, command: command), command, home, judge)
            #expect(applied.result.decision == .deny(Deny(ruleID: RuleID(pack: pack, pattern: pattern), reason: "pack")))
            #expect(applied.log == nil)
        }
        #expect(judge.calls.withLock { $0 } == 0)
    }

    @Test("a pack deny finishes while every admitted judge call is blocked")
    func packDenyRunsBesideBlockedJudgeCalls() async throws {
        // As many offloaded bodies as JudgeAdmission lets block on the model.
        let stuck = JudgeAdmission.liveLimit
        let release = DispatchSemaphore(value: 0)
        let blocked = Mutex(0)
        let denyFinished = Mutex(false)
        let releasedEarly = Mutex(false)
        // Release from a private queue, after the deny finished or a long
        // cap, so a starved queue fails the test instead of hanging it.
        DispatchQueue(label: "test.judge-release").async {
            let started = ContinuousClock.now
            while ContinuousClock.now - started < .seconds(60), denyFinished.withLock({ $0 }) == false {
                Thread.sleep(forTimeInterval: 0.02)
            }
            releasedEarly.withLock { $0 = denyFinished.withLock { $0 } == false }
            for _ in 0..<stuck { release.signal() }
        }
        let home = try emptyHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<stuck {
                group.addTask {
                    await JudgeOffload.run {
                        blocked.withLock { $0 += 1 }
                        release.wait()
                    }
                }
            }
            while blocked.withLock({ $0 }) < stuck {
                try? await Task.sleep(for: .milliseconds(10))
            }
            let (pack, pattern, command) = Self.denies[0]
            let decision = await JudgeOffload.run {
                Self.apply(deny(pack: pack, pattern: pattern, command: command), command, home, CountingJudge())
                    .result.decision
            }
            denyFinished.withLock { $0 = true }
            #expect(decision == .deny(Deny(ruleID: RuleID(pack: pack, pattern: pattern), reason: "pack")))
            await group.waitForAll()
        }
        #expect(releasedEarly.withLock { $0 } == false, "the deny only finished after the judge calls were released")
    }

    static func apply(
        _ result: EvaluationResult, _ command: String, _ home: HomePath, _ judge: any JudgePort
    ) -> JudgeRuntime.Judged {
        JudgeRuntime.apply(
            to: result, command: ShellCommand(rawValue: command),
            inputs: .gather(home: home, cwd: nil, environment: [:]), judge: judge,
            provenance: .unknown, now: Date(), cwd: nil, allowSafeLane: true, isPeek: false
        )
    }
}

/// Counts calls; a pack deny must leave it at zero.
private final class CountingJudge: JudgePort {
    let calls = Mutex(0)
    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        calls.withLock { $0 += 1 }
        return .busy
    }
}

private func deny(pack: PackID, pattern: String, command: String) -> EvaluationResult {
    EvaluationResult(
        outcome: .deny(Deny(ruleID: RuleID(pack: pack, pattern: pattern), reason: "pack"), matched: nil),
        matchingView: MatchingView(rawValue: command),
        analysis: .unknown
    )
}

private func emptyHome() throws -> HomePath {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-deny-bypass-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try #require(HomePath(validating: root.path))
}

private func withEmptyHome(_ body: (HomePath) throws -> Void) throws {
    let home = try emptyHome()
    defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
    try body(home)
}
