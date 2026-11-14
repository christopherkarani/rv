#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy
@testable import RVService
import Synchronization

/// Enforced denies and Policy-gate overrides land in the hash-chained
/// `audit.jsonl`, so `rv audit verify` covers the gate's core action.
@Suite("Gate decisions in the audit chain")
struct GateAuditTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let resetHard = ShellCommand(rawValue: "git reset --hard HEAD~3 # SECRET-MARKER")

    private func home() throws -> (HomeDirectory, URL) {
        let url = try isolatedHomeDirectory()
        return (try #require(HomeDirectory(validating: url.path)), url)
    }

    private func decide(
        _ intent: EvaluationIntent,
        home: HomeDirectory,
        allowlist: AllowlistSnapshot = .empty
    ) async -> (result: EvaluationResult, effects: [GatedEffect]) {
        await GatedEvaluate().decide(
            intent, EvaluationRequest(command: Self.resetHard, enabledPacks: dayOnePackIDs),
            cwd: wd("/tmp/ws"), home: home, grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { allowlist }, host: .hook(.claude), tool: .bash,
            inputs: EvaluationInputs(
                guardMode: .enforce,
                judge: JudgeSelection(engine: .ft, bundle: nil),
                store: .gather(home: nil, cwd: nil)
            )
        )
    }

    private func auditLines(_ home: HomeDirectory) throws -> [String] {
        let url = AuditLog.fileURL(configDirectory: RVPolicyPaths.configDirectory(home: home))
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test func enforcedDenyIsChainedWithoutCommandText() async throws {
        let (home, url) = try home()
        defer { try? FileManager.default.removeItem(at: url) }
        let decided = await decide(.apply, home: home)
        guard case .deny(let deny) = decided.result.decision else {
            Issue.record("git reset --hard must deny, got \(decided.result.decision)")
            return
        }
        GatedEvaluate.perform(decided.effects, home: home)
        let lines = try auditLines(home)
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line.contains("\"command.denied\""))
        #expect(line.contains(deny.ruleID.rawValue))
        #expect(line.contains("SECRET-MARKER") == false, "audit must not carry command text")
        #expect(line.contains("reset --hard") == false)
        let report = AuditChain.verify(Data((lines.joined(separator: "\n") + "\n").utf8))
        #expect(report.isIntact)
        #expect(report.lines == 1)
    }

    @Test func peekWritesNothingToTheChain() async throws {
        let (home, url) = try home()
        defer { try? FileManager.default.removeItem(at: url) }
        let decided = await decide(.peek, home: home)
        GatedEvaluate.perform(decided.effects, home: home)
        #expect(try auditLines(home).isEmpty)
    }

    @Test func allowlistOverrideIsChained() async throws {
        let (home, url) = try home()
        defer { try? FileManager.default.removeItem(at: url) }
        let denied = await decide(.peek, home: home)
        guard case .deny(let deny) = denied.result.decision else {
            Issue.record("expected a deny to override")
            return
        }
        let allowlist = AllowlistSnapshot(entries: [
            AllowlistEntry(selector: .rule(deny.ruleID), reason: "test", addedAt: Self.now.addingTimeInterval(-60)),
        ])
        let decided = await decide(.apply, home: home, allowlist: allowlist)
        guard case .allow = decided.result.decision else {
            Issue.record("allowlisted rule must allow, got \(decided.result.decision)")
            return
        }
        GatedEvaluate.perform(decided.effects, home: home)
        let lines = try auditLines(home)
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line.contains("\"command.override\""))
        #expect(line.contains("\"allowlist\""))
        #expect(line.contains(deny.ruleID.rawValue))
        #expect(line.contains("SECRET-MARKER") == false)
    }

    @Test func anOverrideThatCannotBeAuditedStaysADeny() async throws {
        let (home, url) = try home()
        defer { try? FileManager.default.removeItem(at: url) }
        let denied = await decide(.peek, home: home)
        guard case .deny(let deny) = denied.result.decision else {
            Issue.record("expected a deny to override")
            return
        }
        let allowlist = AllowlistSnapshot(entries: [
            AllowlistEntry(selector: .rule(deny.ruleID), reason: "test", addedAt: Self.now.addingTimeInterval(-60)),
        ])
        // A directory where audit.jsonl belongs: every append fails.
        let log = AuditLog.fileURL(configDirectory: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        let result = await GatedEvaluate().gated(
            .apply, EvaluationRequest(command: Self.resetHard, enabledPacks: dayOnePackIDs),
            cwd: wd("/tmp/ws"), home: home, grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { allowlist }, host: .hook(.claude), tool: .bash,
            inputs: EvaluationInputs(
                guardMode: .enforce,
                judge: JudgeSelection(engine: .ft, bundle: nil),
                store: .gather(home: nil, cwd: nil)
            )
        )
        guard case .deny(let kept) = result.decision else {
            Issue.record("an unrecorded override must stay a deny, got \(result.decision)")
            return
        }
        #expect(kept.ruleID == deny.ruleID)
        #expect(kept.reason == GatedEvaluate.unrecordedOverrideReason)
        // G6: the deny it stays is still written to the denial ledger,
        // a separate file the broken audit log does not block.
        let blocks = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home)).records(asOf: Self.now)
        #expect(blocks.map(\.ruleID) == [deny.ruleID])
    }

    /// Pauses taken on a fake clock: each one is 10 ms of fake time.
    private final class Ticks: Sendable {
        let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func increment() { count.withLock { $0 += 1 } }
    }

    /// L3: the override row and the deny row written when it fails share
    /// one lock wait. Another holder keeps `audit.jsonl` locked; the
    /// override row spends the whole 0.1 s (10 fake pauses) and the deny
    /// row then tries once, without a fresh 0.1 s. The denial ledger, a
    /// separate file, still gets the deny.
    @Test func anUnrecordedOverrideAndItsDenyRowShareOneLockWait() throws {
        let (home, url) = try home()
        defer { try? FileManager.default.removeItem(at: url) }
        let config = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(
            at: config, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let holder = open(AuditLog.fileURL(configDirectory: config).path, O_CREAT | O_RDWR, 0o600)
        #expect(holder >= 0)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX) == 0)
        defer { _ = flock(holder, LOCK_UN) }

        let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
        let denial = GatedEffect.DenialRow(
            at: Self.now, host: .hook(.claude), tool: .bash, ruleID: rule, category: .pack(rule.pack), path: "")
        let row = GatedEffect.OverrideRow(
            at: Self.now, host: .hook(.claude), ruleID: rule, override: "allowlist", workspace: nil, denial: denial)
        let ticks = Ticks()
        let base = ContinuousClock.now
        let recorded = GatedEvaluate.perform([.overrideAudit(row)], home: home, lockWait: {
            AuditLog.LockWait(
                timeout: 0.1,
                now: { base.advanced(by: .milliseconds(10 * ticks.value)) },
                pause: { ticks.increment() })
        })
        #expect(recorded == false)
        #expect(ticks.value == 10, "the deny row must not get a fresh lock wait")
        #expect(DenialLedger(configDirectory: config).records(asOf: Self.now).map(\.ruleID) == [rule])
    }

    @Test func ledgerCopiesOfChainedDeniesAreNotExportedTwice() throws {
        let t = Self.now
        let chained = AuditEvent(time: t, kind: .commandDenied, decision: .denied, subject: "core.git:reset-hard",
                                 source: "audit.jsonl", detail: ["host": "claude"])
        let ledger = AuditEvent(time: t.addingTimeInterval(0.4), kind: .commandDenied, decision: .denied,
                                subject: "core.git:reset-hard", source: "blocks.jsonl", detail: ["host": "claude"])
        let older = AuditEvent(time: t.addingTimeInterval(-3600), kind: .commandDenied, decision: .denied,
                               subject: "core.git:reset-hard", source: "blocks.jsonl", detail: ["host": "claude"])
        let kept = AuditLedger.droppingLedgerDuplicates([chained, ledger, older])
        #expect(kept.count == 2)
        #expect(kept.contains(chained))
        #expect(kept.contains(older))
    }
}
