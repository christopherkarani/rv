#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVAnalytics
import RVDomain
import RVHistory
import RVPolicy
@testable import RVService

/// What the hook-local evaluator does when a record cannot land in its
/// write deadline (docs/architecture/hook-local-decide.md, "Effects"), and
/// how rvd drains what it spooled.
@Suite("Hook-local record failures", .serialized)
struct LocalHookRecordFailureTests {
    /// The whole call, evaluation and writes, ends by the write deadline:
    /// the C hook's 1 s less the reply margin, plus scheduling slack.
    static let callBound = LocalHookDecider.localDeadline - LocalHookDecider.replyMargin + .milliseconds(100)

    static func config(_ fixture: LocalHookFixture) -> URL {
        RVPolicyPaths.configDirectory(home: fixture.home)
    }

    static func envRead(_ fixture: LocalHookFixture) -> String {
        claudeFile("Read", path: fixture.workspace + "/.env", cwd: fixture.workspace)
    }

    // MARK: Audit first, and what a lost audit row costs

    @Test func enforcedDenyWhoseAuditCannotLandEscalatesAndWritesNothing() async throws {
        let fixture = try LocalHookFixture()
        let holder = try FileLockHolder(path: Self.config(fixture).appendingPathComponent("audit.jsonl").path)
        defer { holder.release() }

        let started = ContinuousClock.now
        let outcome = await fixture.decider.decide(host: .claude, stdin: Self.envRead(fixture), started: started)
        let elapsed = ContinuousClock.now - started
        holder.release()

        #expect(outcome == .escalate(.auditUnwritten))
        #expect(elapsed < Self.callBound)
        // rvd re-evaluates and writes every row itself: nothing here first.
        #expect(fixture.configFileExists("blocks.jsonl") == false)
        #expect(HookLocalSpool.drain(home: fixture.home).isEmpty)
    }

    @Test func observeKeepsTheVerdictAndSpoolsTheAuditFieldsForRvd() async throws {
        let fixture = try LocalHookFixture(guardMode: "observe")
        let stdin = try await Self.observedFinalDeny(fixture)
        let audit = Self.config(fixture).appendingPathComponent("audit.jsonl")
        let holder = try FileLockHolder(path: audit.path)
        defer { holder.release() }

        let started = ContinuousClock.now
        let outcome = await fixture.decider.decide(host: .claude, stdin: stdin, started: started)
        let elapsed = ContinuousClock.now - started
        holder.release()

        guard case .final = outcome else {
            Issue.record("observe must keep the local verdict, got \(outcome)")
            return
        }
        #expect(elapsed < Self.callBound)

        let drainer = HookLocalSpoolDrainer(home: fixture.home, deliver: { _ in })
        let drained = await drainer.drainNow()
        #expect(drained.audits.count == 1)
        let row = try #require(drained.audits.first)
        #expect(row.path?.contains(fixture.home.path) != true)
        let text = try String(contentsOf: audit, encoding: .utf8)
        #expect(text.contains(#""recorded_by":"hook-local""#))
        #expect(text.contains(row.rule))
        let report = try AuditChain.verify(fileURL: audit).get()
        #expect(report.isIntact)

        // The verdict is rvd's verdict for the same call.
        let rvd = try await fixture.rvdReply(host: .claude, stdin: stdin)
        #expect(outcome == .final(rvd))
    }

    /// A call the evaluator answers under observe and that writes an audit
    /// row (a deny observe does not step aside from), found by deciding the
    /// equivalence corpus over `fixture` until one does.
    static func observedFinalDeny(_ fixture: LocalHookFixture) async throws -> String {
        let audit = Self.config(fixture).appendingPathComponent("audit.jsonl")
        for call in EquivalenceCorpus.calls(workspace: fixture.workspace, home: fixture.home.path) {
            let before = (try? Data(contentsOf: audit))?.count ?? 0
            guard case .final = await fixture.decider.decide(host: .claude, stdin: call.stdin) else { continue }
            if ((try? Data(contentsOf: audit))?.count ?? 0) > before { return call.stdin }
        }
        throw LocalHookFixtureError.noReply("no observe-mode final deny in the corpus")
    }

    @Test func everyHeldLogSharesOneDeadline() throws {
        let fixture = try LocalHookFixture()
        let config = Self.config(fixture)
        let holders = try [
            "audit.jsonl", "blocks.lock", "judge-log.jsonl.lock", "exemption-drops.jsonl.lock",
            "hook-local-spool.jsonl.lock",
        ].map { try FileLockHolder(path: config.appendingPathComponent($0).path) }
        defer { holders.forEach { $0.release() } }

        let started = ContinuousClock.now
        let deadline = started + .milliseconds(300)
        let record = GatedEvaluate.performBounded(
            Self.effects(fixture), home: fixture.home, deadline: deadline,
            auditFloor: .milliseconds(150), escalateUnrecordedDeny: false)
        let spooled = HookLocalSpool.write(
            HookLocalSpool.Batch(decision: .deny, drops: record.drops, audits: record.audits),
            home: fixture.home, lockTimeout: max(.zero, deadline - ContinuousClock.now))
        let elapsed = ContinuousClock.now - started
        holders.forEach { $0.release() }

        #expect(elapsed < .milliseconds(300) + .milliseconds(100))
        #expect(record.unrecordedDeny == false)
        #expect(record.audits.count == 1)
        #expect(Set(record.drops) == [.exemption, .judgeLog, .denialLedger])
        #expect(spooled == false)
        let drained = HookLocalSpool.drain(home: fixture.home)
        #expect(drained.lostAudits == 1)
        #expect(drained.lost == 4)
    }

    @Test(arguments: [
        "audit.jsonl", "blocks.jsonl", "blocks.lock", "judge-log.jsonl", "judge-log.jsonl.lock",
        "exemption-drops.jsonl", "exemption-drops.jsonl.lock", "config.json", "hook-local-spool.jsonl",
        "hook-local-spool.jsonl.lock", "hook-local-spool.uncounted",
    ])
    func aFIFOAtARecordPathNeverHangs(_ name: String) throws {
        let fixture = try LocalHookFixture()
        let fifo = Self.config(fixture).appendingPathComponent(name)
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let effects = Self.effects(fixture)
        let home = fixture.home
        #expect(NonBlockingOpenTests.finishesPromptly(fifo: fifo) {
            let record = GatedEvaluate.performBounded(
                effects, home: home, deadline: ContinuousClock.now + .milliseconds(300),
                auditFloor: .milliseconds(150), escalateUnrecordedDeny: false)
            HookLocalSpool.write(
                HookLocalSpool.Batch(decision: .deny, drops: record.drops, audits: record.audits), home: home)
            _ = HookLocalSpool.drain(home: home)
        })
    }

    /// An observed deny's audit, ledger, judge-log and exemption rows: no
    /// escalation, so every write is tried.
    static func effects(_ fixture: LocalHookFixture) -> [GatedEffect] {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let row = GatedEffect.DenialRow(
            at: now, host: .hook(.claude), tool: .bash, ruleID: RuleID(rawValue: "core.git:reset-hard")!,
            category: LedgerCategory(rawValue: "core.git")!, path: "", observed: true, wouldBe: .deny)
        let judge = GatedEffect.JudgeLogRow(
            at: now, guardMode: .observe, engine: .ft, hash: "abc", subject: .wouldBe(.deny, rule: nil),
            note: nil, isPeek: false, score: nil)
        return [
            .exemptionAudit(.init(dropped: ["rm -rf build"], workspace: nil, at: now)),
            .judgeLog(judge),
            .denialRow(row),
        ]
    }

    // MARK: rvd's drain

    static func validAudit(rule: String = "core.git:reset-hard") -> HookLocalSpool.Audit {
        HookLocalSpool.Audit(
            kind: "command.observed", rule: rule, host: "claude", tool: "Bash", category: "core.git",
            path: nil, wouldBe: "deny", at: 1_790_000_000)
    }

    @Test func drainWithTheSpoolLockHeldReturnsAtOnceAndKeepsTheRows() async throws {
        let fixture = try LocalHookFixture()
        for _ in 0..<3 { #expect(HookLocalSpool.write(.init(decision: .allow, drops: []), home: fixture.home)) }
        let holder = try FileLockHolder(path: HookLocalSpool.fileURL(home: fixture.home).path + ".lock")
        defer { holder.release() }
        let drainer = HookLocalSpoolDrainer(home: fixture.home, deliver: { _ in })

        let started = ContinuousClock.now
        let held = await drainer.drainNow()
        #expect(ContinuousClock.now - started < .milliseconds(100))
        #expect(held.decisions.isEmpty)

        holder.release()
        #expect(await drainer.drainNow().decisions == [.allow: 3])
    }

    @Test func concurrentWritesAndDrainsLoseAndDoubleNothing() async throws {
        let fixture = try LocalHookFixture()
        let home = fixture.home
        let total = 300
        let drainer = HookLocalSpoolDrainer(home: home, deliver: { _ in })
        let finished = UnfairLock(false)
        Thread {
            DispatchQueue.concurrentPerform(iterations: total) { _ in
                HookLocalSpool.write(.init(decision: .allow, drops: []), home: home)
            }
            finished.withLock { $0 = true }
        }.start()
        var landed = 0
        var lost = 0
        while finished.withLock({ $0 }) == false {
            let drained = await drainer.drainNow()
            landed += drained.decisions[.allow] ?? 0
            lost += drained.lost
        }
        let last = await drainer.drainNow()
        landed += last.decisions[.allow] ?? 0
        lost += last.lost
        #expect(landed + lost == total)
        #expect(await drainer.drainNow().isEmpty)
    }

    @Test func drainerAppendsRecoveredRowsAndAGapAndLogsOncePerMinute() async throws {
        let fixture = try LocalHookFixture()
        #expect(HookLocalSpool.write(
            .init(decision: nil, drops: [.judgeLog], audits: [Self.validAudit()]), home: fixture.home))
        try Data("aax".utf8).write(to: HookLocalSpool.uncountedURL(home: fixture.home))
        let lines = UnfairLock([String]())
        let drainer = HookLocalSpoolDrainer(
            home: fixture.home, deliver: { _ in }, write: { line in lines.withLock { $0.append(line) } })

        let drained = await drainer.drainNow()
        #expect(drained.audits == [Self.validAudit()])
        #expect(drained.lostAudits == 2)
        #expect(drained.lost == 1)
        #expect(drained.drops == [.judgeLog: 1])

        let audit = AuditLog.fileURL(configDirectory: Self.config(fixture))
        let rows = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n")
        #expect(rows.count == 2)
        #expect(rows.first?.contains(#""recorded_by":"hook-local""#) == true)
        #expect(rows.last?.contains(#""kind":"audit.gap""#) == true)
        #expect(rows.last?.contains(#""lost":"2""#) == true)
        #expect(try AuditChain.verify(fileURL: audit).get().isIntact)

        let logged = lines.withLock { $0 }
        #expect(logged.count == 1)
        #expect(logged.first?.contains("core.git:reset-hard") == true)
        #expect(logged.first?.hasPrefix("rvd:") == false, "a timestamped RVDLogFile line")

        #expect(HookLocalSpool.write(.init(decision: nil, drops: [.exemption]), home: fixture.home))
        await drainer.drainNow()
        #expect(lines.withLock { $0.count } == 1)
    }

    @Test func forgedAuditFieldsAreCountedNotAppended() async throws {
        let fixture = try LocalHookFixture()
        let forged = [
            #"{"v":1,"dropped":"audit","audit":{"kind":"config.changed","rule":"core.git:reset-hard","host":"claude","tool":"Bash","category":"core.git","at":1790000000}}"#,
            #"{"v":1,"dropped":"audit","audit":{"kind":"command.denied","rule":"not a rule","host":"claude","tool":"Bash","category":"core.git","at":1790000000}}"#,
            #"{"v":1,"dropped":"audit","audit":{"kind":"command.denied","rule":"core.git:reset-hard","host":"claude","tool":"Bash","category":"core.git","wouldBe":"deny","at":1790000000}}"#,
            #"{"v":1,"dropped":"audit"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(forged.utf8).write(to: HookLocalSpool.fileURL(home: fixture.home))
        let drained = await HookLocalSpoolDrainer(home: fixture.home, deliver: { _ in }).drainNow()
        #expect(drained.audits.isEmpty)
        #expect(drained.lostAudits == 4)
        let text = try String(
            contentsOf: AuditLog.fileURL(configDirectory: Self.config(fixture)), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 1)
        #expect(text.contains(#""kind":"audit.gap""#))
    }

    @Test func oversizedSpoolCountsTheBytesItDrops() throws {
        let fixture = try LocalHookFixture()
        try Data(repeating: UInt8(ascii: "\n"), count: HookLocalSpool.maxBytes + 100)
            .write(to: HookLocalSpool.fileURL(home: fixture.home))
        let drained = HookLocalSpool.drain(home: fixture.home)
        #expect(drained.truncatedBytes == 100)
        #expect(HookLocalSpool.drain(home: fixture.home).isEmpty)
    }

    @Test func timerDrainsWithoutAnEvaluation() async throws {
        let fixture = try LocalHookFixture()
        #expect(HookLocalSpool.write(.init(decision: .deny, drops: []), home: fixture.home))
        let delivered = UnfairLock([AnalyticsDecisionKind: Int]())
        let drainer = HookLocalSpoolDrainer(home: fixture.home, deliver: { drained in
            delivered.withLock { $0.merge(drained.decisions, uniquingKeysWith: +) }
        })
        drainer.startTimer(every: .milliseconds(50))
        let deadline = ContinuousClock.now + .seconds(5)
        while delivered.withLock({ $0.isEmpty }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(delivered.withLock { $0 } == [.deny: 1])
    }
}
