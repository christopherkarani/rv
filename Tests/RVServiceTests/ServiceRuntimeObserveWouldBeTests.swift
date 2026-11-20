import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

/// The SDK `evaluate` reply carries, under observe, the verdict enforce
/// would have returned (`wouldBe`) next to the observed allow, so SDK
/// callers see what `rv test` / `rv explain` show.
@Suite("Service evaluate observe would-be")
struct ServiceRuntimeObserveWouldBeTests {
    /// `ledgerRows` reads the ledger as of this instant.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let cwd = wd("/tmp/ws")

    private static func runtime(home: HomeDirectory, allowOnceDirectory: URL? = nil) throws -> ServiceRuntime {
        ServiceRuntime(
            home: home,
            allowOnceDirectory: try allowOnceDirectory ?? isolatedAllowOnceDirectory(),
            clock: { now }
        )
    }

    private static func evaluate(_ command: String, home: HomeDirectory) async throws -> EvaluateReply {
        try await evaluate(command, runtime: runtime(home: home))
    }

    /// Over the same-UID SDK socket, as an SDK client calls it.
    private static func evaluate(
        _ command: String, runtime: ServiceRuntime, cwd: WorkingDirectory? = nil
    ) async throws -> EvaluateReply {
        let request = EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs)
        let response = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: cwd))),
            sameUIDSocket: true
        )
        guard case .evaluate(let reply) = response.result else {
            Issue.record("expected an evaluate reply, got \(response.result)")
            throw CancellationError()
        }
        return reply
    }

    @Test("observe: the reply is the observed allow and wouldBe is enforce's deny")
    func observeCarriesWouldBeDeny() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let reply = try await Self.evaluate("git reset --hard", home: home)
        #expect(reply.result.decision == .allow)
        guard case .deny(let deny)? = reply.wouldBe?.decision else {
            Issue.record("expected a would-be deny, got \(String(describing: reply.wouldBe))")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test("observe, no judge bundle: an inline program's wouldBe is enforce's indeterminate")
    func observeCarriesFlooredIndeterminate() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let reply = try await Self.evaluate(#"python3 -c 'print(shred)'"#, home: home)
        #expect(reply.result.decision == .allow)
        #expect(reply.wouldBe?.decision == .indeterminate(.inlineProgramNeedsJudge))
    }

    @Test("observe: an allow enforce would also allow carries no wouldBe")
    func observeAllowHasNoWouldBe() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let reply = try await Self.evaluate("git status", home: home)
        #expect(reply.result.decision == .allow)
        #expect(reply.wouldBe == nil)
    }

    @Test("enforce: the reply is the deny and carries no wouldBe")
    func enforceHasNoWouldBe() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let reply = try await Self.evaluate("git reset --hard", home: home)
        guard case .deny = reply.result.decision else {
            Issue.record("enforce must deny, got \(reply.result.decision)")
            return
        }
        #expect(reply.wouldBe == nil)
    }

    // The would-be preview is a peek: it adds no rows and spends no grant.

    @Test("observe: a would-be deny records one observed denial row and one judge row")
    func observeWritesOneDenialRow() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let reply = try await Self.evaluate("git reset --hard", runtime: Self.runtime(home: home))
        #expect(reply.wouldBe != nil)
        let rows = ledgerRows(home)
        #expect(rows.count == 1)
        #expect(rows.first?.observed == true)
        #expect(try judgeLog(home).count == 1)
    }

    @Test("observe: a live allow-once grant gives no wouldBe and stays live")
    func observeGrantStaysLive() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let runtime = try Self.runtime(home: home)
        _ = await runtime.insertGranted(matchingView: "git reset --hard", cwd: Self.cwd, now: Self.now)
        let observed = try await Self.evaluate("git reset --hard", runtime: runtime, cwd: Self.cwd)
        #expect(observed.result.decision == .allow)
        #expect(observed.wouldBe == nil)
        #expect(ledgerRows(home).isEmpty)
        #expect(await runtime.hasLiveAllowOnceGrants())

        // Enforce now spends that same grant once, then denies.
        try FileManager.default.removeItem(
            at: RVPolicyPaths.configDirectory(home: home).appendingPathComponent("config.json")
        )
        let spent = try await Self.evaluate("git reset --hard", runtime: runtime, cwd: Self.cwd)
        #expect(spent.result.decision == .allow)
        #expect(!(await runtime.hasLiveAllowOnceGrants()))
        let denied = try await Self.evaluate("git reset --hard", runtime: runtime, cwd: Self.cwd)
        guard case .deny = denied.result.decision else {
            Issue.record("enforce must deny once the grant is spent, got \(denied.result.decision)")
            return
        }
    }

    @Test("observe: an allowlisted deny gives no wouldBe")
    func observeAllowlistedDenyHasNoWouldBe() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        try AllowlistStore(baseDirectory: allowOnceDirectory).add(
            AllowlistEntry(selector: .rule(ruleID), reason: "ci", addedAt: Self.now),
            tty: TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        )
        let runtime = try Self.runtime(home: home, allowOnceDirectory: allowOnceDirectory)
        let reply = try await Self.evaluate("git reset --hard", runtime: runtime, cwd: Self.cwd)
        #expect(reply.result.decision == .allow)
        #expect(reply.wouldBe == nil)
        #expect(ledgerRows(home).isEmpty)
    }
}
