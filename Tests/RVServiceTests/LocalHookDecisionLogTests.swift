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

    @Test func aLocalAndAnRvdRowForTheSameCallMatch() async throws {
        let fixture = try LocalHookFixture()
        let stdin = claudeBash("ls -la", cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        guard case .final = local else {
            Issue.record("a safe-lane allow must be decided locally, got \(local)")
            return
        }
        let localRow = try #require(fixture.decisionRows().first)
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let rvdRow = DecisionLogRecorder.shellRecord(
            EvaluationResult(outcome: .plain), command: ShellCommand(rawValue: "ls -la"),
            cwd: WorkingDirectory(validating: fixture.workspace), host: .hook(.claude),
            home: fixture.home, at: time, timedOut: false)
        #expect(localRow.command == rvdRow.command)
        #expect(localRow.cwd == rvdRow.cwd)
        #expect(localRow.host == rvdRow.host)
        #expect(localRow.tool == rvdRow.tool)
    }

    // MARK: - The call's id and would-be

    @Test func aLocalFileDenySharesItsIDWithTheLedgerRow() async throws {
        let fixture = try LocalHookFixture()
        let stdin = claudeFile("Read", path: fixture.workspace + "/.env", cwd: fixture.workspace)
        guard case .final = await fixture.decider.decide(host: .claude, stdin: stdin) else {
            Issue.record("a file deny must be decided locally")
            return
        }
        let row = try #require(fixture.decisionRows().first)
        let id = try #require(row.id)
        #expect(id.wholeMatch(of: /[0-9a-f]{12}/) != nil)
        #expect(row.wouldBe == nil)
        let ledger = try #require(fixture.ledgerRows().first)
        #expect(ledger.id == id)
        #expect(ledger.code == row.code)
        #expect(row.code == DecisionStamp.code(forID: id))
    }

    @Test func inWatchModeAWouldStopGoesToRvdAndLogsNothingHere() async throws {
        let fixture = try LocalHookFixture(guardMode: "observe")
        let stdin = claudeFile("Read", path: fixture.workspace + "/.env", cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        #expect(local == .escalate(.observe))
        #expect(fixture.decisionRows().isEmpty)
    }

    /// rvd answers the would-stop: its allowed decision row carries what
    /// guarding would have done, and the id of its observed ledger row.
    @Test func rvdsWatchModeAllowCarriesTheWouldBeAndTheLedgerID() async throws {
        let fixture = try LocalHookFixture(guardMode: "observe")
        let runtime = ServiceRuntime(
            snapshots: nil, catalog: nil, home: fixture.home, allowOnce: nil,
            allowOnceDirectory: try isolatedAllowOnceDirectory(), idleExitSeconds: IdleWatchdog.defaultSeconds,
            log: nil, analytics: nil, clock: { Date() }, pendingApprovals: .automatic,
            ceremonies: WorkspaceOperatorCeremonyService(), hookBudget: testHookBudget, recordsDecisions: true
        )
        let stdin = claudeFile("Read", path: fixture.workspace + "/.env", cwd: fixture.workspace)
        _ = await runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .claude, stdin: stdin))),
            context: peerHookContext()
        )
        // The row is written after the reply; give it a moment.
        var rows = fixture.decisionRows()
        for _ in 0..<100 where rows.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            rows = fixture.decisionRows()
        }
        let row = try #require(rows.first)
        let ledger = try #require(fixture.ledgerRows().first)
        #expect(ledger.observed)
        #expect(row.verdict == .allowed)
        #expect(row.wouldBe?.verdict == .denied)
        #expect(row.wouldBe?.rule == ledger.ruleID.rawValue)
        #expect(row.wouldBe?.ask == (ledger.wouldBe == .ask))
        #expect(row.id != nil && row.id == ledger.id)
    }

    @Test func everyCallGetsItsOwnID() async throws {
        let fixture = try LocalHookFixture()
        for command in ["ls -la", "pwd"] {
            guard case .final = await fixture.decider.decide(
                host: .claude, stdin: claudeBash(command, cwd: fixture.workspace))
            else {
                Issue.record("a safe-lane allow must be decided locally")
                return
            }
        }
        let rows = fixture.decisionRows()
        #expect(rows.count == 2)
        #expect(Set(rows.compactMap(\.id)).count == 2)
        #expect(rows.allSatisfy { $0.wouldBe == nil })
    }
}

extension LocalHookFixture {
    func ledgerRows() -> [DenialLedgerRecord] {
        DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home)).records(asOf: Date())
    }

    func decisionRows() -> [DecisionRecord] {
        DecisionLog(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .records(since: .distantPast, now: Date())
    }
}
