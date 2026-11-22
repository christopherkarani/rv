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
        let fixture = try LocalHookFixture(localDeadline: LocalHookDecider.localDeadline)
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
        let fixture = try LocalHookFixture(guardMode: "observe", localDeadline: LocalHookDecider.localDeadline)
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

    /// One fixed time near now: a spooled row must be within a day of its drain.
    static let validAt = Date().timeIntervalSince1970

    static func validAudit(rule: String = "core.git:reset-hard", at: Double = validAt) -> HookLocalSpool.Audit {
        HookLocalSpool.Audit(
            kind: "command.observed", rule: rule, host: "claude", tool: "Bash", category: "core.git",
            path: nil, wouldBe: "deny", at: at)
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
        // Lost rows are counted one drain late.
        for _ in 0..<2 {
            let last = await drainer.drainNow()
            landed += last.decisions[.allow] ?? 0
            lost += last.lost
        }
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
        #expect(drained.drops == [.judgeLog: 1])
        // The uncounted bytes are counted by the next drain.
        let counted = await drainer.drainNow()
        #expect(counted.lostAudits == 2)
        #expect(counted.lost == 1)

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
        try Data(repeating: UInt8(ascii: "\n"), count: HookLocalSpool.maxBytes + HookLocalSpool.readSlack + 100)
            .write(to: HookLocalSpool.fileURL(home: fixture.home))
        let drained = HookLocalSpool.drain(home: fixture.home)
        #expect(drained.truncatedBytes == 100)
        // Bytes dropped unread may have been audit rows: a gap is recorded.
        #expect(drained.atLeast)
        #expect(drained.lostAudits == 1)
        #expect(HookLocalSpool.drain(home: fixture.home).isEmpty)
    }

    @Test func aBatchThatCrossedTheCapIsStillRead() throws {
        let fixture = try LocalHookFixture()
        var data = Data(repeating: UInt8(ascii: "\n"), count: HookLocalSpool.maxBytes - 10)
        data.append(Data((#"{"decision":"allow","v":1}"# + "\n").utf8))
        try data.write(to: HookLocalSpool.fileURL(home: fixture.home))
        let drained = HookLocalSpool.drain(home: fixture.home)
        #expect(drained.decisions == [.allow: 1])
        #expect(drained.truncatedBytes == 0)
        #expect(drained.atLeast == false)
    }

    @Test func aTornTailIsALostRowAndAGap() throws {
        let fixture = try LocalHookFixture()
        #expect(HookLocalSpool.write(.init(decision: .allow, drops: []), home: fixture.home))
        let handle = try FileHandle(forWritingTo: HookLocalSpool.fileURL(home: fixture.home))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"v":1,"dropped":"au"#.utf8))
        try handle.close()
        let drained = HookLocalSpool.drain(home: fixture.home)
        #expect(drained.decisions == [.allow: 1])
        #expect(drained.lost == 1)
        #expect(drained.lostAudits == 1)
        #expect(drained.atLeast)
    }

    @Test func aFullUncountedFileMakesTheGapALowerBound() async throws {
        let fixture = try LocalHookFixture()
        let full = Data(repeating: HookLocalSpool.lostRowByte, count: HookLocalSpool.maxUncountedBytes)
        try full.write(to: HookLocalSpool.uncountedURL(home: fixture.home))
        let drained = HookLocalSpool.drain(home: fixture.home)
        #expect(drained.lost == HookLocalSpool.maxUncountedBytes)
        #expect(drained.atLeast)
        #expect(drained.lostAudits == 1)

        try full.write(to: HookLocalSpool.uncountedURL(home: fixture.home))
        let drainer = HookLocalSpoolDrainer(home: fixture.home, deliver: { _ in })
        await drainer.drainNow()
        await drainer.drainNow()
        let text = try String(contentsOf: AuditLog.fileURL(configDirectory: Self.config(fixture)), encoding: .utf8)
        #expect(text.contains(#""kind":"audit.gap""#))
        #expect(text.contains(#""at_least":"true""#))
    }

    // MARK: A failed append keeps the rows

    @Test func aFailedAppendKeepsTheRowsForALaterDrainThatChainsThem() async throws {
        let fixture = try LocalHookFixture()
        let audits = [Self.validAudit(rule: "core.git:reset-hard"), Self.validAudit(rule: "core.git:clean-force")]
        #expect(HookLocalSpool.write(.init(decision: .deny, drops: [], audits: audits), home: fixture.home))
        let audit = AuditLog.fileURL(configDirectory: Self.config(fixture))
        let holder = try FileLockHolder(path: audit.path)
        defer { holder.release() }
        let lines = UnfairLock([String]())
        let drainer = HookLocalSpoolDrainer(
            home: fixture.home, deliver: { _ in }, write: { line in lines.withLock { $0.append(line) } })
        let draining = HookLocalSpool.drainingURL(home: fixture.home).path

        let held = await drainer.drainNow()
        #expect(held.audits.isEmpty)
        #expect(held.kept == 2)
        #expect(held.decisions == [.deny: 1])
        #expect(FileManager.default.fileExists(atPath: draining))
        #expect(lines.withLock { $0.first?.contains("2 spooled row(s) left for the next drain") } == true)

        holder.release()
        let later = await drainer.drainNow()
        #expect(later.audits == audits)
        #expect(later.decisions.isEmpty, "the decision was taken once")
        #expect(FileManager.default.fileExists(atPath: draining) == false)
        let rows = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n")
        #expect(rows.count == 2)
        #expect(try AuditChain.verify(fileURL: audit).get().isIntact)
    }

    @Test func aGapThatCannotBeAppendedIsCountedAgain() async throws {
        let fixture = try LocalHookFixture()
        try Data("aa".utf8).write(to: HookLocalSpool.uncountedURL(home: fixture.home))
        let drainer = HookLocalSpoolDrainer(home: fixture.home, deliver: { _ in })
        await drainer.drainNow()  // moves the count aside for the next drain
        let audit = AuditLog.fileURL(configDirectory: Self.config(fixture))
        let holder = try FileLockHolder(path: audit.path)
        defer { holder.release() }
        #expect(await drainer.drainNow().lostAudits == 2)
        holder.release()
        #expect(try Data(contentsOf: HookLocalSpool.uncountedURL(home: fixture.home)) == Data("aa".utf8))
        await drainer.drainNow()
        #expect(await drainer.drainNow().lostAudits == 2)
        let text = try String(contentsOf: audit, encoding: .utf8)
        #expect(text.contains(#""kind":"audit.gap""#))
        #expect(text.contains(#""lost":"2""#))
    }

    @Test func oneDrainTakesAtMostItsRowCap() throws {
        let fixture = try LocalHookFixture()
        for _ in 0..<5 { #expect(HookLocalSpool.write(.init(decision: .allow, drops: []), home: fixture.home)) }
        let first = HookLocalSpool.drain(home: fixture.home, now: Date(), maxRows: 3) { _ in true }
        #expect(first.decisions == [.allow: 3])
        #expect(first.kept == 2)
        let second = HookLocalSpool.drain(home: fixture.home, now: Date(), maxRows: 3) { _ in true }
        #expect(second.decisions == [.allow: 2])
        #expect(second.kept == 0)
    }

    @Test func rowsOutOfTimeOrWithOverlongRulesAreGapsNotChained() async throws {
        let fixture = try LocalHookFixture()
        let now = Date().timeIntervalSince1970
        #expect(HookLocalSpool.write(.init(decision: nil, drops: [], audits: [
            Self.validAudit(at: now - 25 * 3600),
            Self.validAudit(at: now + 25 * 3600),
            Self.validAudit(rule: "core.git:" + String(repeating: "x", count: 300)),
            Self.validAudit(at: now - 23 * 3600),
        ]), home: fixture.home))
        let drained = await HookLocalSpoolDrainer(home: fixture.home, deliver: { _ in }).drainNow()
        #expect(drained.audits.count == 1)
        #expect(drained.lostAudits == 3)
    }

    // MARK: Planted files at the spool paths

    @Test(arguments: ["symlink", "fifo", "hardlink"])
    func aPlantedSpoolOrUncountedFileIsRemovedAndCounted(_ kind: String) throws {
        for target in ["spool", "uncounted"] {
            let fixture = try LocalHookFixture()
            let url = target == "spool"
                ? HookLocalSpool.fileURL(home: fixture.home) : HookLocalSpool.uncountedURL(home: fixture.home)
            let other = Self.config(fixture).appendingPathComponent("other.txt")
            try Data("keep".utf8).write(to: other)
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
            case "fifo": #expect(mkfifo(url.path, 0o600) == 0)
            default: #expect(link(other.path, url.path) == 0)
            }
            // A planted file refuses the evaluator's write, never redirects it.
            HookLocalSpool.write(.init(decision: .allow, drops: []), home: fixture.home)
            #expect(try Data(contentsOf: other) == Data("keep".utf8), "\(target) \(kind)")
            let drained = HookLocalSpool.drain(home: fixture.home, now: Date()) { _ in true }
            #expect(drained.atLeast, "\(target) \(kind)")
            #expect(drained.lostAudits >= 1)
            #expect(try Data(contentsOf: other) == Data("keep".utf8))
            // The spool works again.
            #expect(HookLocalSpool.write(.init(decision: .allow, drops: []), home: fixture.home), "\(target) \(kind)")
        }
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

extension HookLocalSpool {
    /// Two drains that append every row, merged: uncounted counts reach
    /// the drain after the one that moved them aside.
    static func drain(home: HomeDirectory) -> Drained {
        var drained = drain(home: home, now: Date()) { _ in true }
        drained.add(drain(home: home, now: Date()) { _ in true })
        return drained
    }
}

extension HookLocalSpool.Drained {
    mutating func add(_ other: Self) {
        decisions.merge(other.decisions, uniquingKeysWith: +)
        drops.merge(other.drops, uniquingKeysWith: +)
        audits += other.audits
        lostAudits += other.lostAudits
        lost += other.lost
        truncatedBytes += other.truncatedBytes
        atLeast = atLeast || other.atLeast
        kept += other.kept
    }
}
