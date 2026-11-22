import Foundation
import Testing
import RVAnalytics
import RVDomain
import RVHistory
import RVIPC
import RVPolicy
@testable import RVService

/// What a locally decided hook call records, against what rvd records for
/// the same call (docs/architecture/hook-local-decide.md, "Effects").
///
/// Two identical homes: the local evaluator decides every call over one,
/// and rvd's hook door answers each call the local evaluator finalized over
/// the other, both on one fixed clock. Every row either side writes (the
/// hash-chained audit, the denial ledger, the judge log, the exemption
/// audit) must be the same bytes, and the analytics counts rvd ingests from
/// the local spool must equal the counts rvd records itself.
@Suite("Hook-local record parity", .serialized)
struct LocalHookRecordParityTests {
    static let records = ["audit.jsonl", "blocks.jsonl", "judge-log.jsonl", "exemption-drops.jsonl"]

    @Test(arguments: [nil, "observe"] as [String?])
    func localRowsAreRvdsRows(_ guardMode: String?) async throws {
        let local = try LocalHookFixture(guardMode: guardMode)
        let rvd = try LocalHookFixture(guardMode: guardMode)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let decider = LocalHookDecider(home: local.home, clock: { now }, localDeadline: testLocalDeadline)
        let rvdAnalytics = Self.coordinator(home: rvd.home)
        let runtime = hookTestRuntime(
            home: rvd.home, allowOnceDirectory: try isolatedAllowOnceDirectory(),
            analytics: rvdAnalytics, clock: { now })

        var finals = 0
        var shellFinals = 0
        let calls = EquivalenceCorpus.calls(workspace: local.workspace, home: local.home.path)
        for (index, call) in calls.enumerated() where index % 9 == 0 || !call.isBash {
            guard case .final = await decider.decide(host: .claude, stdin: call.stdin) else { continue }
            finals += 1
            if call.isBash { shellFinals += 1 }
            // The same call, rewritten for rvd's home.
            let stdin = call.stdin
                .replacingOccurrences(of: local.home.path, with: rvd.home.path)
                .replacingOccurrences(of: Self.jsonEscaped(local.home.path), with: Self.jsonEscaped(rvd.home.path))
            _ = try await LocalHookEquivalenceTests.rvdReply(runtime, stdin: stdin)
        }
        #expect(finals > 100)
        #expect(shellFinals > 50)

        for name in Self.records {
            let mine = Self.text(name, local.home)
                .replacingOccurrences(of: Self.jsonEscaped(local.home.path), with: "<home>")
                .replacingOccurrences(of: local.home.path, with: "<home>")
            let theirs = Self.text(name, rvd.home)
                .replacingOccurrences(of: Self.jsonEscaped(rvd.home.path), with: "<home>")
                .replacingOccurrences(of: rvd.home.path, with: "<home>")
            let first = zip(mine.split(separator: "\n"), theirs.split(separator: "\n")).first { $0 != $1 }
            #expect(mine == theirs, """
                \(name) differs (\(mine.split(separator: "\n").count) local rows, \
                \(theirs.split(separator: "\n").count) rvd rows)
                local: \(first.map { String($0.0) } ?? "-")
                rvd:   \(first.map { String($0.1) } ?? "-")
                """)
        }
        // The calls wrote something to compare.
        #expect(Self.text("audit.jsonl", local.home).isEmpty == false)
        #expect(Self.text("blocks.jsonl", local.home).isEmpty == false)

        // rvd ingests the spool the local evaluator wrote.
        let localAnalytics = Self.coordinator(home: local.home)
        let drainer = HookLocalSpoolDrainer(home: local.home, deliver: { drained in
            await localAnalytics.recordDecisions(drained.decisions)
            await localAnalytics.flushDailyIfNeeded()
        })
        await drainer.drainNow()
        let ingested = try Self.counts(local.home)
        #expect(ingested.total == shellFinals)
        let recorded = try await Self.awaitCounts(rvd.home, total: shellFinals)
        #expect(ingested == recorded)
        // Drained: a second drain adds nothing.
        await drainer.drainNow()
        #expect(try Self.counts(local.home) == ingested)
    }

    @Test func analyticsOptOutSpoolsNoDecision() async throws {
        let fixture = try LocalHookFixture()
        let config = RVPolicyPaths.configDirectory(home: fixture.home)
        try Data(#"{"analytics":{"enabled":false}}"#.utf8).write(to: config.appendingPathComponent("config.json"))
        let outcome = await fixture.decider.decide(host: .claude, stdin: claudeBash("ls", cwd: fixture.workspace))
        guard case .final = outcome else {
            Issue.record("ls must be decided locally, got \(outcome)")
            return
        }
        #expect(HookLocalSpool.drain(home: fixture.home) == HookLocalSpool.Drained())
    }

    struct Counts: Equatable {
        let allow: Int
        let deny: Int
        let indeterminate: Int
        var total: Int { allow + deny + indeterminate }
    }

    /// A coordinator whose sink never accepts, so no flush resets its counts.
    static func coordinator(home: HomeDirectory) -> AnalyticsCoordinator {
        AnalyticsCoordinator(
            paths: AnalyticsPaths(configDirectory: RVPolicyPaths.configDirectory(home: home)),
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "parity"),
            sink: NoOpAnalyticsSink(),
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354"))
    }

    static func counts(_ home: HomeDirectory) throws -> Counts {
        let file = RVPolicyPaths.configDirectory(home: home).appendingPathComponent("analytics-counters.json")
        guard let data = FileManager.default.contents(atPath: file.path) else { return Counts(allow: 0, deny: 0, indeterminate: 0) }
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Counts(
            allow: object["allowCount"] as? Int ?? -1,
            deny: object["denyCount"] as? Int ?? -1,
            indeterminate: object["indeterminateCount"] as? Int ?? -1)
    }

    /// rvd records analytics on a task of its own; wait for it to land.
    static func awaitCounts(_ home: HomeDirectory, total: Int) async throws -> Counts {
        let deadline = ContinuousClock.now + .seconds(30)
        var last = try counts(home)
        while last.total < total, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            last = try counts(home)
        }
        return last
    }

    /// A path as JSONSerialization and JSONEncoder write it (`/` as `\/`).
    static func jsonEscaped(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "\\/")
    }

    static func text(_ name: String, _ home: HomeDirectory) -> String {
        let url = RVPolicyPaths.configDirectory(home: home).appendingPathComponent(name)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// The spool's own bounds: a held lock or a full or symlinked spool costs
/// a count, never a wait. A held audit log and the shared write deadline
/// are in `LocalHookRecordFailureTests`.
@Suite("Hook-local record budget", .serialized)
struct LocalHookRecordBudgetTests {
    @Test func heldSpoolCountsTheLostRowsWithoutALock() throws {
        let fixture = try LocalHookFixture()
        let spool = HookLocalSpool.fileURL(home: fixture.home)
        let holder = try FileLockHolder(path: spool.path + ".lock")
        defer { holder.release() }
        let started = ContinuousClock.now
        let landed = HookLocalSpool.write(
            HookLocalSpool.Batch(decision: .allow, drops: [.judgeLog]), home: fixture.home)
        #expect(landed == false)
        #expect(ContinuousClock.now - started < HookLocalSpool.lockTimeout + .milliseconds(500))
        holder.release()
        let drained = HookLocalSpool.drain(home: fixture.home)
        #expect(drained.decisions.isEmpty)
        #expect(drained.lost == 2)
    }

    @Test func spoolRoundTripsAndSkipsGarbage() throws {
        let fixture = try LocalHookFixture()
        #expect(HookLocalSpool.write(.init(decision: .allow, drops: []), home: fixture.home))
        #expect(HookLocalSpool.write(.init(decision: .deny, drops: [.audit, .denialLedger]), home: fixture.home))
        #expect(HookLocalSpool.write(.init(decision: nil, drops: []), home: fixture.home))
        let handle = try FileHandle(forWritingTo: HookLocalSpool.fileURL(home: fixture.home))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n{\"v\":1,\"decision\":\"maybe\"}\n".utf8))
        try handle.close()
        let drained = HookLocalSpool.drain(home: fixture.home)
        #expect(drained.decisions == [.allow: 1, .deny: 1])
        #expect(drained.drops == [.denialLedger: 1])
        // An audit drop without its fields is a lost audit row.
        #expect(drained.lostAudits == 1)
        #expect(drained.lost == 2)
        #expect(HookLocalSpool.drain(home: fixture.home) == HookLocalSpool.Drained())
    }

    @Test func fullSpoolCountsInsteadOfGrowing() throws {
        let fixture = try LocalHookFixture()
        let spool = HookLocalSpool.fileURL(home: fixture.home)
        try Data(repeating: UInt8(ascii: "\n"), count: HookLocalSpool.maxBytes).write(to: spool)
        #expect(HookLocalSpool.write(.init(decision: .allow, drops: []), home: fixture.home) == false)
        let size = try FileManager.default.attributesOfItem(atPath: spool.path)[.size] as? Int
        #expect(size == HookLocalSpool.maxBytes)
        #expect(HookLocalSpool.drain(home: fixture.home).lost == 1)
    }

    @Test func symlinkedSpoolIsNeverFollowed() throws {
        let fixture = try LocalHookFixture()
        let spool = HookLocalSpool.fileURL(home: fixture.home)
        let target = spool.deletingLastPathComponent().appendingPathComponent("elsewhere.txt")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: spool, withDestinationURL: target)
        #expect(HookLocalSpool.write(.init(decision: .allow, drops: []), home: fixture.home) == false)
        #expect(try Data(contentsOf: target).isEmpty)
    }
}

/// Holds an exclusive `flock` on `path` from another process until released.
final class FileLockHolder: @unchecked Sendable {
    private let process: Process

    init(path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e",
            #"use Fcntl qw(:flock); open(F, ">>", $ARGV[0]) or die; flock(F, LOCK_EX) or die; $| = 1; print "locked\n"; sleep 30"#,
            path,
        ]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let ready = out.fileHandleForReading.readData(ofLength: 7)
        guard String(decoding: ready, as: UTF8.self) == "locked\n" else {
            process.terminate()
            throw LocalHookFixtureError.noReply("lock holder did not start")
        }
        self.process = process
    }

    func release() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}
