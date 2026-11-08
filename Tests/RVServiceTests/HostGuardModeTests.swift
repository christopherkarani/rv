import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy
@testable import RVService

/// Per-host guard mode (`guard.hosts.<host>`) and observe-mode would-be
/// denial rows.
@Suite("Per-host guard mode")
struct HostGuardModeTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let packDeny = ShellCommand(rawValue: "rm -rf ~")

    private static func config(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test("RV_GUARD_MODE > guard.hosts.<host> > guard.mode > enforce")
    func precedence() throws {
        let config = try Self.config(
            #"{"guard":{"mode":"observe","hosts":{"claude":"block","cursor":"observe","codex":"off","grok":"loud"}}}"#
        )
        func mode(_ env: [String: String], _ host: HookHost?) -> GuardMode {
            JudgeRuntime.guardMode(environment: env, config: config, host: host)
        }
        #expect(mode([:], .claude) == .enforce)
        #expect(mode([:], .cursor) == .observe)
        #expect(mode([:], .codex) == .observe)
        // Unknown value and no entry fall through to guard.mode.
        #expect(mode([:], .grok) == .observe)
        #expect(mode([:], .pi) == .observe)
        #expect(mode([:], nil) == .observe)
        #expect(mode(["RV_GUARD_MODE": "enforce"], .cursor) == .enforce)
        #expect(mode(["RV_GUARD_MODE": "observe"], .claude) == .observe)
        let bare = try Self.config(#"{"guard":{"hosts":{"cursor":"observe"}}}"#)
        #expect(JudgeRuntime.guardMode(environment: [:], config: bare, host: .claude) == .enforce)
        #expect(JudgeRuntime.guardMode(environment: [:], config: bare, host: nil) == .enforce)
    }

    @Test("gather reads the evaluating host's entry; tty has none")
    func gatherUsesHost() throws {
        let home = try hostHome(#"{"guard":{"hosts":{"claude":"observe"}}}"#)
        defer { remove(home) }
        func mode(_ host: LedgerHost) -> GuardMode {
            EvaluationInputs.gather(home: home, cwd: nil, environment: [:], host: host).guardMode
        }
        #expect(mode(.hook(.claude)) == .observe)
        #expect(mode(.hook(.cursor)) == .enforce)
        #expect(mode(.tty) == .enforce)
    }

    @Test("observe host: apply allows, writes an observed row and a command.observed audit event")
    func observeHostApplyRecordsObservedRow() async throws {
        let home = try hostHome(#"{"guard":{"hosts":{"claude":"observe"}}}"#)
        defer { remove(home) }
        let observed = await GatedEvaluate().apply(
            command: Self.packDeny, cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        #expect(observed.decision == .allow)
        let enforced = await GatedEvaluate().apply(
            command: Self.packDeny, cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.cursor)
        )
        guard case .deny(let deny) = enforced.decision else {
            Issue.record("block host must deny, got \(enforced.decision)")
            return
        }
        let rows = ledgerRows(home)
        #expect(rows.count == 2)
        let observedRow = try #require(rows.first { $0.host == .hook(.claude) })
        #expect(observedRow.observed)
        #expect(observedRow.ruleID == deny.ruleID)
        let enforcedRow = try #require(rows.first { $0.host == .hook(.cursor) })
        #expect(enforcedRow.observed == false)
        let events = AuditLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .events(AuditFilter(kinds: ["command"]))
        #expect(events.filter { $0.kind == .commandObserved }.map(\.decision) == [.info])
        #expect(events.filter { $0.kind == .commandDenied }.map(\.decision) == [.denied])
        #expect(events.allSatisfy { $0.source == AuditLedger.Source.audit.rawValue })
    }

    @Test("observe host: peek records nothing")
    func observeHostPeekRecordsNothing() async throws {
        let home = try hostHome(#"{"guard":{"hosts":{"claude":"observe"}}}"#)
        defer { remove(home) }
        let result = await GatedEvaluate().peek(
            command: Self.packDeny, cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        #expect(result.decision == .allow)
        #expect(ledgerRows(home).isEmpty)
    }

    @Test("off host still never blocks: a stale hook observes")
    func offHostObserves() async throws {
        let home = try hostHome(#"{"guard":{"hosts":{"codex":"off"}}}"#)
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: Self.packDeny, cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.codex)
        )
        #expect(result.decision == .allow)
        #expect(ledgerRows(home).map(\.observed) == [true])
    }

    @Test("observe host: file door allows a secret read and writes an observed row")
    func observeHostFileDoor() throws {
        let home = try hostHome(#"{"guard":{"hosts":{"claude":"observe"}}}"#)
        defer { remove(home) }
        let action = FileToolAction(kind: .read, path: FileToolPath(rawValue: home.rawValue + "/.env"))
        let observed = GatedEvaluate().runFile(action, home: home, host: .hook(.claude), now: Self.now)
        #expect(observed.decision == .allow)
        let enforced = GatedEvaluate().runFile(action, home: home, host: .hook(.cursor), now: Self.now)
        guard case .deny = enforced.decision else {
            Issue.record("block host file door must deny, got \(enforced.decision)")
            return
        }
        let rows = ledgerRows(home)
        #expect(rows.first { $0.host == .hook(.claude) }?.observed == true)
        #expect(rows.first { $0.host == .hook(.claude) }?.category == .secret(.environment))
        #expect(rows.first { $0.host == .hook(.cursor) }?.observed == false)
    }

    @Test("observed rows respect blocks.enabled; the audit chain still records them")
    func observedRowsRespectBlocksEnabled() async throws {
        let home = try hostHome(#"{"blocks":{"enabled":false},"guard":{"hosts":{"claude":"observe"}}}"#)
        defer { remove(home) }
        _ = await GatedEvaluate().apply(
            command: Self.packDeny, cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        #expect(ledgerRows(home).isEmpty)
        let events = AuditLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .events(AuditFilter(kinds: ["command.observed"]))
        #expect(events.count == 1)
    }

    @Test("observe allow with no would-be deny writes no row")
    func observeAllowWritesNoRow() async throws {
        let home = try hostHome(#"{"guard":{"hosts":{"claude":"observe"}}}"#)
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: "ls -la"), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        #expect(result.decision == .allow)
        #expect(ledgerRows(home).isEmpty)
    }
}

private func hostHome(_ config: String) throws -> HomeDirectory {
    let home = try guardHome(mode: nil)
    let directory = RVPolicyPaths.configDirectory(home: home)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try config.write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    return home
}
