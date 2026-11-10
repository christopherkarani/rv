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
    // Not `rm -rf ~`: that also removes rv's install, which observe never relaxes.
    private static let packDeny = ShellCommand(rawValue: "rm -rf ~/Documents")

    private static func config(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test("RV_GUARD_MODE=enforce > guard.hosts.<host> > guard.mode > enforce")
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
        // The environment only tightens: observe from env is ignored.
        #expect(mode(["RV_GUARD_MODE": "observe"], .claude) == .enforce)
        #expect(mode(["RV_GUARD_MODE": "observe"], .cursor) == .observe)
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
        // No cwd: nothing to unlock, so enforcement would have denied.
        #expect(observedRow.wouldBe == .deny)
        #expect(observedRow.ruleID == deny.ruleID)
        let enforcedRow = try #require(rows.first { $0.host == .hook(.cursor) })
        #expect(enforcedRow.observed == false)
        let events = AuditLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .events(AuditFilter(kinds: ["command"]))
        #expect(events.filter { $0.kind == .commandObserved }.map(\.decision) == [.info])
        #expect(events.filter { $0.kind == .commandObserved }.map { $0.detail["would_be"] } == ["deny"])
        #expect(events.filter { $0.kind == .commandDenied }.map { $0.detail["would_be"] } == [nil])
        #expect(events.filter { $0.kind == .commandDenied }.map(\.decision) == [.denied])
        #expect(events.allSatisfy { $0.source == AuditLedger.Source.audit.rawValue })
    }

    @Test("observe host: a would-be ask writes would_be ask to the ledger and the audit chain")
    func observeHostApplyRecordsWouldAsk() async throws {
        let home = try hostHome(#"{"guard":{"hosts":{"claude":"observe"}}}"#)
        defer { remove(home) }
        let observed = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: WorkingDirectory(validating: home.rawValue), home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        #expect(observed.decision == .allow)
        let row = try #require(ledgerRows(home).first)
        #expect(row.observed)
        #expect(row.wouldBe == .ask)
        let events = AuditLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .events(AuditFilter(kinds: ["command.observed"]))
        #expect(events.map { $0.detail["would_be"] } == ["ask"])
    }

    @Test("a stored block outranks a global guard.mode observe")
    func storedBlockBeatsGlobalObserve() async throws {
        let home = try hostHome(#"{"guard":{"mode":"observe"}}"#)
        defer { remove(home) }
        try HostModeStore(configDirectory: RVPolicyPaths.configDirectory(home: home)).save(.block, for: .claude)
        let mode = EvaluationInputs.gather(home: home, cwd: nil, environment: [:], host: .hook(.claude)).guardMode
        #expect(mode == .enforce)
        let result = await GatedEvaluate().apply(
            command: Self.packDeny, cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        guard case .deny = result.decision else {
            Issue.record("an explicit block host must deny under global observe, got \(result.decision)")
            return
        }
        #expect(ledgerRows(home).map(\.observed) == [false])
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

    // Observe never relaxes rv's own protection: an observe host must not
    // loosen another host (or the global guard) through rv's config or an
    // rv admin command.

    @Test("observe host: file door still denies writing rv's config.json")
    func observeHostFileDoorKeepsRVConfig() throws {
        let home = try hostHome(#"{"guard":{"hosts":{"claude":"observe"}}}"#)
        defer { remove(home) }
        let config = home.rawValue + "/.config/rv/config.json"
        for kind in [FileToolKind.write, .edit, .read] {
            let action = FileToolAction(kind: kind, path: FileToolPath(rawValue: config))
            let result = GatedEvaluate().runFile(action, home: home, host: .hook(.claude), now: Self.now)
            guard case .deny(let deny) = result.decision else {
                Issue.record("\(kind) of config.json must deny under observe, got \(result.decision)")
                continue
            }
            #expect(deny.ruleID == RuleID(pack: .coreSecrets, pattern: "home-rv-config"))
        }
        #expect(ledgerRows(home).allSatisfy { $0.observed == false })
    }

    @Test("observe host: rv self-protection and rv-config writes stay enforced", arguments: [
        "rv host mode cursor off",
        "rv host mode claude observe",
        "rv uninstall",
        "rv packs disable core.git",
        "git reset --hard && rv host mode cursor off",
        "echo '{}' > ~/.config/rv/config.json",
        "git reset --hard; echo '{}' > ~/.config/rv/config.json",
    ])
    func observeHostShellKeepsSelfProtection(command: String) async throws {
        let home = try hostHome(#"{"guard":{"hosts":{"claude":"observe"}}}"#)
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: command), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        #expect(result.decision != .allow, "\(command)")
        #expect(ledgerRows(home).allSatisfy { $0.observed == false }, "\(command)")
        let agent = GatedEvaluate().evaluateAgent(
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
            cwd: nil, home: home, now: Self.now,
            inputs: EvaluationInputs.gather(home: home, cwd: nil, environment: [:], host: .hook(.claude))
        )
        #expect(agent.decision != .allow, "agent door: \(command)")
    }

    // An agent that stops or replaces rvd makes every later call
    // unreachable, which observe allows unchecked: these stay enforced.
    @Test("observe host: stopping or replacing rvd stays enforced", arguments: [
        "launchctl bootout gui/501/dev.rv.evaluate",
        "systemctl --user stop dev.rv.evaluate.service",
        "pkill -f rvd",
        "launchctl setenv RV_GUARD_MODE observe",
        "rm ~/.local/bin/rvd",
        "mv /tmp/evil ~/.local/bin/rvd",
        "echo x > ~/Library/LaunchAgents/dev.rv.evaluate.plist",
        "git reset --hard; rm ~/.local/bin/rvd",
        "git reset --hard && launchctl bootout gui/501/dev.rv.evaluate",
        "rv setup --observe",
        "rm -rf ~",
    ])
    func observeHostShellKeepsRVDLifecycle(command: String) async throws {
        let home = try hostHome(#"{"guard":{"hosts":{"claude":"observe"}}}"#)
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: command), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        #expect(result.decision != .allow, "\(command)")
        #expect(ledgerRows(home).allSatisfy { $0.observed == false }, "\(command)")
    }

    // The stop/install floors are observe-only: an enforce host must not be
    // newly floored, and the everyday commands these resemble stay allowed.
    @Test("enforce host: install-adjacent everyday commands stay allowed", arguments: [
        "export PATH=\"$HOME/.local/bin:$PATH\"",
        // Not `npm test`: with no cwd its script graph is unresolved, so the
        // package-script gate asks on every host.
        "PATH=$HOME/.local/bin:$PATH swift test",
        "open ~/.local/bin",
        "rg foo ~",
        "git -C ~ status",
        "pkill -f 'rails s'",
        "pkill -P $$",
        "git commit -m 'fix: pkill rvd bug'",
        "swift build --product rv",
    ])
    func enforceHostEverydayAllowed(command: String) async throws {
        let home = try hostHome(#"{"guard":{"hosts":{"claude":"block"}}}"#)
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: command), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        #expect(result.decision == .allow, "\(command)")
    }

    // On an enforce host stopping rvd fails closed on its own; the floor is
    // not added there, so these keep their base (non-floored) verdict.
    @Test("enforce host: stopping or replacing rvd is not a self-protection floor", arguments: [
        "launchctl bootout gui/501/dev.rv.evaluate",
        "pkill -f rvd",
    ])
    func enforceHostNoLifecycleFloor(command: String) async throws {
        let home = try hostHome(#"{"guard":{"hosts":{"claude":"block"}}}"#)
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: command), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        if case .indeterminate(.selfProtection) = result.decision {
            Issue.record("enforce host newly floored: \(command)")
        }
    }

    @Test("observe host: file door never allows writing rv's install; reads are observed allows", arguments: [
        "/.local/bin/rvd",
        "/.local/bin/rv",
        "/Library/LaunchAgents/dev.rv.evaluate.plist",
        "/.config/systemd/user/dev.rv.evaluate.service",
    ])
    func observeHostFileDoorKeepsInstall(suffix: String) throws {
        let home = try hostHome(#"{"guard":{"hosts":{"claude":"observe"}}}"#)
        defer { remove(home) }
        let path = FileToolPath(rawValue: home.rawValue + suffix)
        for kind in [FileToolKind.write, .edit] {
            let result = GatedEvaluate().runFile(
                FileToolAction(kind: kind, path: path), home: home, host: .hook(.claude), now: Self.now
            )
            #expect(result.decision != .allow, "\(kind) \(suffix)")
        }
        let read = GatedEvaluate().runFile(
            FileToolAction(kind: .read, path: path), home: home, host: .hook(.claude), now: Self.now
        )
        #expect(read.decision == .allow, "read \(suffix)")
    }

    @Test("global guard.mode observe keeps the same floor")
    func globalObserveKeepsSelfProtection() async throws {
        let home = try hostHome(#"{"guard":{"mode":"observe"}}"#)
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: "rv host mode cursor off"), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        #expect(result.decision == .indeterminate(.selfProtection))
    }

    @Test("observe host: an ordinary pack deny is still observed")
    func observeHostStillObservesOrdinaryDenies() async throws {
        let home = try hostHome(#"{"guard":{"hosts":{"claude":"observe"}}}"#)
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: "git reset --hard"), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        #expect(result.decision == .allow)
        let rows = ledgerRows(home)
        #expect(rows.map(\.observed) == [true])
        #expect(rows.first?.ruleID == RuleID(pack: .coreGit, pattern: "reset-hard"))
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
