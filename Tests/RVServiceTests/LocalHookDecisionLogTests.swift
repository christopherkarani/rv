import Foundation
import Testing
import RVDomain
import RVHistory
import RVIPC
import RVPolicy
@testable import RVService

/// The hook-local evaluator writes the decision-log row rvd would write for
/// a call it answers itself, so `rv term` sees calls rvd never hears about,
/// and writes none for a call it hands to rvd.
@Suite("Hook-local decision log")
struct LocalHookDecisionLogTests {
    @Test func aLocalAllowIsLogged() async throws {
        let fixture = try LocalHookFixture()
        let local = await fixture.decider.decide(host: .claude, stdin: claudeBash("ls -la", cwd: fixture.workspace))
        guard case .final = local else {
            Issue.record("a safe-lane allow must be decided locally, got \(local)")
            return
        }
        let rows = fixture.decisionRows()
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.verdict == .allowed)
        #expect(row.tool == .bash)
        #expect(row.command == "ls -la")
        #expect(row.cwd == "~/work")
        #expect(row.rule == nil)
        #expect(row.session == "local-hook-test")
    }

    @Test func aLocalFileDenyIsLoggedRedacted() async throws {
        let fixture = try LocalHookFixture()
        let stdin = claudeFile("Read", path: fixture.workspace + "/.env", cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        guard case .final = local else {
            Issue.record("a file deny must be decided locally, got \(local)")
            return
        }
        let row = try #require(fixture.decisionRows().first)
        #expect(row.verdict == .denied)
        #expect(row.path == "~/work/.env")
        #expect(row.command == nil)
        #expect(row.rule?.isEmpty == false)
    }

    @Test func anEscalationLogsNothing() async throws {
        let fixture = try LocalHookFixture()
        let local = await fixture.decider.decide(
            host: .claude, stdin: claudeBash("git reset --hard", cwd: fixture.workspace))
        #expect(local == .escalate(.policyGate))
        #expect(fixture.decisionRows().isEmpty)
    }

    @Test func turnedOffLogsNothing() async throws {
        let fixture = try LocalHookFixture()
        try Data(#"{"decisions":{"enabled":false}}"#.utf8)
            .write(to: RVPolicyPaths.configDirectory(home: fixture.home).appendingPathComponent("config.json"))
        let local = await fixture.decider.decide(host: .claude, stdin: claudeBash("ls -la", cwd: fixture.workspace))
        guard case .final = local else {
            Issue.record("a safe-lane allow must be decided locally, got \(local)")
            return
        }
        #expect(fixture.decisionRows().isEmpty)
    }

    /// The same call, answered locally in one home and by rvd in another,
    /// leaves the same row (but for its time).
    @Test func aLocalRowIsTheRowRvdWrites() async throws {
        let local = try LocalHookFixture()
        let outcome = await local.decider.decide(host: .claude, stdin: claudeBash("ls -la", cwd: local.workspace))
        guard case .final = outcome else {
            Issue.record("a safe-lane allow must be decided locally, got \(outcome)")
            return
        }
        let localRow = try #require(local.decisionRows().first)

        let rvd = try LocalHookFixture()
        let runtime = hookTestRuntime(
            home: rvd.home, allowOnceDirectory: try isolatedAllowOnceDirectory(), recordsDecisions: true)
        _ = await runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(
                host: .claude, stdin: claudeBash("ls -la", cwd: rvd.workspace)))),
            context: peerHookContext())
        // rvd writes its row detached, after the reply.
        var rvdRows: [DecisionRecord] = []
        let started = ContinuousClock.now
        while rvdRows.isEmpty, ContinuousClock.now - started < .seconds(10) {
            try await Task.sleep(for: .milliseconds(20))
            rvdRows = rvd.decisionRows()
        }
        let rvdRow = try #require(rvdRows.first)
        #expect(rvdRows.count == 1)
        var aligned = rvdRow
        aligned.time = localRow.time
        #expect(aligned == localRow)
    }
}

extension LocalHookFixture {
    func decisionRows() -> [DecisionRecord] {
        DecisionLog(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .records(since: .distantPast, now: Date())
    }
}
