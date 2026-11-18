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
        allowlist: AllowlistSnapshot = .empty,
        command: ShellCommand = Self.resetHard,
        guardMode: GuardMode = .enforce
    ) async -> (result: EvaluationResult, effects: [GatedEffect]) {
        await GatedEvaluate().decide(
            intent, EvaluationRequest(command: command, enabledPacks: dayOnePackIDs),
            cwd: wd("/tmp/ws"), home: home, grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { allowlist }, host: .hook(.claude), tool: .bash,
            inputs: EvaluationInputs(
                guardMode: guardMode,
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

    // MARK: - Indeterminate refusals (F6)

    /// rv administration from the agent: the engine floors it to
    /// `indeterminate(.selfProtection)` on every host and mode.
    private static let selfProtected = ShellCommand(rawValue: "rv host mode claude off")
    /// Over the engine's 64 KiB command cap: `indeterminate(.commandTooLarge)`.
    private static let oversized = ShellCommand(rawValue: String(repeating: "a", count: 65_537))

    private func chained(_ home: HomeDirectory) throws -> [AuditEvent] {
        var events: [AuditEvent] = []
        for line in try auditLines(home) {
            events.append(try #require(AuditLedger.event(fromLine: Substring(line), source: .audit)))
        }
        return events
    }

    /// The hook door refuses an indeterminate verdict; it is chained as a
    /// `command.denied` marked as an unfinished evaluation, with the reason
    /// class and no command text. The reply is the refusal it always was.
    @Test func anIndeterminateRefusalIsChainedAsAMarkedDeny() async throws {
        let (home, url) = try home()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await GatedEvaluate().apply(
            command: Self.selfProtected, cwd: wd("/tmp/ws"), home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        #expect(result.decision == .indeterminate(.selfProtection))
        #expect(HookAuthorization.project(result: result, cwd: wd("/tmp/ws")) == .denyPinned)
        let lines = try auditLines(home)
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line.contains("host mode") == false, "audit must not carry command text")
        #expect(line.contains("claude off") == false)
        let event = try #require(AuditLedger.event(fromLine: Substring(line), source: .audit))
        #expect(event.kind == .commandDenied)
        #expect(event.decision == .denied)
        #expect(event.subject == "rv.indeterminate:selfProtection")
        #expect(event.reason == "selfProtection")
        #expect(event.detail["verdict"] == "indeterminate")
        #expect(event.detail["host"] == "claude")
        #expect(event.detail["tool"] == "Bash")
        #expect(event.detail["would_be"] == nil)
        #expect(event.agent == "claude")
        let report = AuditChain.verify(Data((lines.joined(separator: "\n") + "\n").utf8))
        #expect(report.isIntact)
        #expect(report.lines == 1)
        // The denial ledger is rule-oriented (`rv blocks`, the review queue
        // offers allow-once); an indeterminate is neither, so it stays out.
        let blocks = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home)).records(asOf: Self.now)
        #expect(blocks.isEmpty)
    }

    @Test func anIndeterminatePeekWritesNothingToTheChain() async throws {
        let (home, url) = try home()
        defer { try? FileManager.default.removeItem(at: url) }
        let decided = await decide(.peek, home: home, command: Self.selfProtected)
        #expect(decided.result.decision == .indeterminate(.selfProtection))
        GatedEvaluate.perform(decided.effects, home: home)
        #expect(try auditLines(home).isEmpty)
    }

    /// Observe never relaxes self-protection: the refusal stands and is
    /// chained as a refusal, not as an observed would-be.
    @Test func observeKeepsASelfProtectionRefusalAndChainsItAsADeny() async throws {
        let (home, url) = try home()
        defer { try? FileManager.default.removeItem(at: url) }
        let decided = await decide(.apply, home: home, command: Self.selfProtected, guardMode: .observe)
        #expect(decided.result.decision == .indeterminate(.selfProtection))
        GatedEvaluate.perform(decided.effects, home: home)
        let events = try chained(home)
        #expect(events.map(\.kind) == [.commandDenied])
        #expect(events.first?.subject == "rv.indeterminate:selfProtection")
        #expect(events.first?.detail["verdict"] == "indeterminate")
        #expect(events.first?.detail["would_be"] == nil)
    }

    /// Observe lets any other unfinished evaluation run (today's behaviour,
    /// unchanged): it is chained as an observed would-be refusal.
    @Test func observeLetsAnUnresolvedScriptGraphRunAndChainsItAsObserved() async throws {
        let (home, url) = try home()
        defer { try? FileManager.default.removeItem(at: url) }
        let pkg = try packageDir(script: "node ok.js")
        defer { try? FileManager.default.removeItem(at: pkg) }
        let cwd = WorkingDirectory(rawValue: pkg.path)
        let request = EvaluationRequest(command: ShellCommand(rawValue: #"cd "$D" && npm test"#), enabledPacks: dayOnePackIDs)
        func decideScript(_ mode: GuardMode) async -> (result: EvaluationResult, effects: [GatedEffect]) {
            await GatedEvaluate().decide(
                .apply, request, cwd: cwd, home: home, grants: EphemeralAllowOnceTable(), now: Self.now,
                allowlist: { .empty }, host: .hook(.claude), tool: .bash,
                inputs: EvaluationInputs(
                    guardMode: mode,
                    judge: JudgeSelection(engine: .ft, bundle: nil),
                    store: .gather(home: home, cwd: cwd)
                )
            )
        }
        let enforced = await decideScript(.enforce)
        #expect(enforced.result.decision == .indeterminate(.packageScriptUnresolved))
        let observed = await decideScript(.observe)
        #expect(observed.result.decision == .allow)
        GatedEvaluate.perform(observed.effects, home: home)
        let lines = try auditLines(home)
        #expect(lines.count == 1)
        #expect(lines.allSatisfy { $0.contains("npm test") == false }, "audit must not carry command text")
        let events = try chained(home)
        let event = try #require(events.first)
        #expect(event.kind == .commandObserved)
        #expect(event.decision == .info)
        #expect(event.subject == "rv.indeterminate:packageScriptUnresolved")
        #expect(event.reason == "packageScriptUnresolved")
        #expect(event.detail["verdict"] == "indeterminate")
        #expect(event.detail["would_be"] == "deny")
        #expect(AuditChain.verify(Data((lines.joined(separator: "\n") + "\n").utf8)).isIntact)
    }

    /// The file door: observe floors a write of rv's install (a systemd user
    /// unit that is not rv's own wiring file) to "run it in Terminal". That
    /// refusal is chained; a log that cannot be written changes nothing.
    @Test func theFileDoorChainsAnIndeterminateRefusal() throws {
        let (home, url) = try home()
        defer { try? FileManager.default.removeItem(at: url) }
        let action = FileToolAction(
            kind: .write, path: FileToolPath(rawValue: home.rawValue + "/.config/systemd/user/other.service"))
        let decided = GatedEvaluate().decideFile(
            action, home: home, cwd: nil, host: .hook(.claude), now: Self.now, guardMode: .observe)
        #expect(decided.result.decision == .indeterminate(.selfProtection))
        GatedEvaluate.perform(decided.effects, home: home)
        let events = try chained(home)
        #expect(events.map(\.kind) == [.commandDenied])
        #expect(events.first?.subject == "rv.indeterminate:selfProtection")
        #expect(events.first?.detail["verdict"] == "indeterminate")
        #expect(events.first?.detail["tool"] == "Write")

        let (broken, brokenURL) = try self.home()
        defer { try? FileManager.default.removeItem(at: brokenURL) }
        let log = AuditLog.fileURL(configDirectory: RVPolicyPaths.configDirectory(home: broken))
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        let brokenAction = FileToolAction(
            kind: .write, path: FileToolPath(rawValue: broken.rawValue + "/.config/systemd/user/other.service"))
        let result = GatedEvaluate().runFile(
            brokenAction, home: broken, cwd: nil, host: .hook(.claude), now: Self.now, guardMode: .observe)
        #expect(result.decision == .indeterminate(.selfProtection))
    }

    /// Recording changes no verdict: for each indeterminate candidate on
    /// the shell door, in each mode, apply returns what peek returns, and
    /// an audit log that cannot be written leaves that verdict as it is.
    @Test func recordingAnIndeterminateNeverChangesTheVerdict() async throws {
        let cases: [(command: ShellCommand, mode: GuardMode, expected: Decision)] = [
            (Self.selfProtected, .enforce, .indeterminate(.selfProtection)),
            (Self.selfProtected, .observe, .indeterminate(.selfProtection)),
            (Self.oversized, .enforce, .indeterminate(.commandTooLarge)),
            // Observe lets an unfinished evaluation run (recorded as observed).
            (Self.oversized, .observe, .allow),
        ]
        for (command, mode, expected) in cases {
            let label = "\(command.rawValue.prefix(24)) \(mode)"
            let (home, url) = try home()
            defer { try? FileManager.default.removeItem(at: url) }
            let peeked = await decide(.peek, home: home, command: command, guardMode: mode)
            let applied = await decide(.apply, home: home, command: command, guardMode: mode)
            #expect(peeked.result.decision == expected, "\(label)")
            #expect(applied.result.decision == expected, "\(label)")
            // A directory where audit.jsonl belongs: every append fails.
            let log = AuditLog.fileURL(configDirectory: RVPolicyPaths.configDirectory(home: home))
            try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
            let gated = await GatedEvaluate().gated(
                .apply, EvaluationRequest(command: command, enabledPacks: dayOnePackIDs),
                cwd: wd("/tmp/ws"), home: home, grants: EphemeralAllowOnceTable(), now: Self.now,
                allowlist: { .empty }, host: .hook(.claude), tool: .bash,
                inputs: EvaluationInputs(
                    guardMode: mode,
                    judge: JudgeSelection(engine: .ft, bundle: nil),
                    store: .gather(home: nil, cwd: nil)
                )
            )
            #expect(gated.decision == expected, "\(label)")
            if case .indeterminate = expected {
                #expect(HookAuthorization.project(result: gated, cwd: wd("/tmp/ws")) == .denyPinned, "\(label)")
            }
        }
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
