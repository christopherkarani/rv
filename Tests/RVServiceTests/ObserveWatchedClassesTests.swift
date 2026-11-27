import Foundation
import Testing
import RVDomain
import RVEngine
import RVPolicy
@testable import RVService

/// Honest watch mode (North Star C1, Chris's Q5): under observe only
/// catastrophic commands and rv's own protection stop. An unresolved path,
/// a write outside the repository and nesting past the unwrap limit are
/// watched (logged as a would-be stop, then run); enforce stops each.
@Suite("Observe: watched classes vs stopped in every mode")
struct ObserveWatchedClassesTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: The floor's rule, one class at a time

    private static let classDenies: [Deny] = [
        ActionPolicyEngine.Builtin.unresolvedFilesystem,
        ActionPolicyEngine.Builtin.outsideRepository,
        ActionPolicyEngine.Builtin.unwrapLimited,
    ]

    @Test("the watched classes are exactly unresolved-path, out-of-repo-write, unwrap-limited")
    func watchedClassSet() {
        #expect(ObserveFloor.watchedClasses == [.unresolvedPath, .outOfRepoWrite, .unwrapLimited])
        for deny in Self.classDenies {
            #expect(ObserveFloor.isWatchedClass(deny.ruleID), "\(deny.ruleID.rawValue)")
        }
        #expect(ObserveFloor.isWatchedClass(ActionPolicyEngine.Builtin.protectedPath.ruleID) == false)
        #expect(ObserveFloor.isWatchedClass(RuleID(pack: .coreGit, pattern: "reset-hard")) == false)
    }

    /// A readable command with a watched-class deny is observed.
    @Test("floor: a watched-class deny on a readable command is observed", arguments: classDenies)
    func readableClassDenyIsObserved(deny: Deny) {
        #expect(floorRule("touch /etc/x", result: Self.denied(deny)) == .observed)
    }

    /// A command rv cannot see still stops (it could switch rv off), but
    /// as `observe.floor:unanalyzable`, never as the class's own hard deny.
    @Test("floor: a watched-class deny rv cannot see stops as unanalyzable", arguments: classDenies)
    func opaqueClassDenyStopsAsUnanalyzable(deny: Deny) {
        let ruling = floorRule(#"eval "$X"; touch /etc/x"#, result: Self.denied(deny))
        #expect(ruling == .enforce(EvaluationResult(outcome: .indeterminate(.observeUnanalyzable))))
    }

    @Test("floor: any other deny rv cannot see keeps its own rule")
    func opaquePackDenyIsKept() {
        let deny = Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x")
        let result = Self.denied(deny)
        #expect(floorRule(#"eval "$X"; git reset --hard"#, result: result) == .enforce(result))
    }

    @Test("floor: a watched-class deny that touches rv keeps its deny")
    func selfProtectionKeepsClassDeny() throws {
        let home = try #require(HomeDirectory(rawValue: "/Users/agent"))
        let result = Self.denied(ActionPolicyEngine.Builtin.outsideRepository)
        #expect(floorRule("touch ~/.local/bin/rvd", result: result, home: home) == .enforce(result))
    }

    // MARK: Through the gate: observe vs enforce

    @Test(
        "a watched class: observe lets it run with a would-be stop, enforce stops it",
        arguments: [
            ("touch /etc/rv-watched", BuiltinRule.outOfRepoWrite),
            ("cp notes.txt /opt/rv-watched/notes.txt", .outOfRepoWrite),
            ("rm -rf /tmp/rv-a /tmp/rv-b", .outOfRepoWrite),
            ("env env env env env env env env env env ls", .unwrapLimited),
            (#"bash -c 'bash -c "bash -c \"bash -c ls\""'"#, .unwrapLimited),
        ]
    )
    func watchedInObserveStoppedInEnforce(command: String, rule: BuiltinRule) async throws {
        let place = try Self.place()
        defer { remove(place.observe); remove(place.enforce) }
        let observed = await Self.verdict(command, home: place.observe, cwd: place.cwd)
        #expect(observed.result.decision == .allow, "\(command)")
        #expect(observed.stoppedInEveryMode == false)
        #expect(observed.wouldBe?.result.decision == .deny(Self.builtin(rule)), "\(command)")
        #expect(observed.wouldBe?.authorization == .denyPinned)
        let enforced = await Self.verdict(command, home: place.enforce, cwd: place.cwd)
        #expect(enforced.result.decision == .deny(Self.builtin(rule)), "\(command)")
        #expect(enforced.wouldBe == nil)
        #expect(enforced.stoppedInEveryMode == false)
    }

    /// Part of the command is a program rv cannot read: enforce stops it on
    /// the class's rule; observe stops it too, for rv's own protection.
    @Test(
        "a watched class rv cannot see: stopped in every mode, as unanalyzable under observe",
        arguments: [
            (#"perl -e 'alarm 20; exec @ARGV' npx --no-install @smithery/cli --help"#, BuiltinRule.unwrapLimited),
            (#"bash -c "$(cat f)""#, .unwrapLimited),
            (#"eval "$X"; touch /etc/rv-watched"#, .outOfRepoWrite),
        ]
    )
    func opaqueClassStopsInEveryMode(command: String, rule: BuiltinRule) async throws {
        let place = try Self.place()
        defer { remove(place.observe); remove(place.enforce) }
        let observed = await Self.verdict(command, home: place.observe, cwd: place.cwd)
        #expect(observed.result.decision == .indeterminate(.observeUnanalyzable), "\(command)")
        #expect(observed.stoppedInEveryMode)
        let enforced = await Self.verdict(command, home: place.enforce, cwd: place.cwd)
        #expect(enforced.result.decision == .deny(Self.builtin(rule)), "\(command)")
    }

    /// Mac report (C1): under observe the hook still asked on an output
    /// redirect to a file and on a command whose text only contains
    /// `rm -rf`. Neither stops under observe: a redirect outside the
    /// repository is a watched would-be stop, the others are allowed.
    @Test(
        "redirects and rm -rf in text never stop under observe",
        arguments: [
            "echo hi > out.txt",
            "swift build 2>&1 > build.log",
            "echo hi > /tmp/out.txt",
            "npm test > /tmp/test.log 2>&1",
            "ls -la > ~/notes.txt",
            "printf '%s\\n' 'rm -rf x' > notes.md",
            "cat > script.sh <<'EOF'\nrm -rf build\nEOF",
            #"echo "rm -rf build""#,
            "echo 'rm -rf ~'",
            #"git commit -m "drop rm -rf usage""#,
            #"grep -rn "rm -rf" ."#,
            #"gh pr create --body "run rm -rf node_modules first""#,
        ]
    )
    func redirectsAndRmRfTextAreWatched(command: String) async throws {
        let place = try Self.place()
        defer { remove(place.observe); remove(place.enforce) }
        let observed = await Self.verdict(command, home: place.observe, cwd: place.cwd)
        #expect(observed.result.decision == .allow, "\(command)")
        #expect(observed.stoppedInEveryMode == false, "\(command)")
        if let wouldBe = observed.wouldBe, wouldBe.result.decision != .allow {
            // What enforce would do is still reported, not done.
            let enforced = await Self.verdict(command, home: place.enforce, cwd: place.cwd)
            #expect(enforced.result.decision == wouldBe.result.decision, "\(command)")
        }
    }

    @Test(
        "catastrophic commands and rv's own files stop in observe, as in enforce",
        arguments: [
            "rm -rf ~",
            "rm -rf /",
            "chmod -R 777 /",
            "cat ~/.config/rv/config.json",
            "echo x > ~/.claude/settings.json",
            "rv host mode claude off",
        ]
    )
    func stoppedInEveryMode(command: String) async throws {
        let place = try Self.place()
        defer { remove(place.observe); remove(place.enforce) }
        let observed = await Self.verdict(command, home: place.observe, cwd: place.cwd)
        #expect(observed.result.decision != .allow, "\(command)")
        #expect(observed.stoppedInEveryMode, "\(command)")
        let enforced = await Self.verdict(command, home: place.enforce, cwd: place.cwd)
        #expect(enforced.result.decision != .allow, "\(command)")
        #expect(enforced.stoppedInEveryMode == false)
    }

    // MARK: Catastrophic (Mac stress run of #674)

    /// A device-wide wipe, format or erase, or a delete of the root, the
    /// home directory or a top-level system directory, stops in observe as
    /// in enforce, under its own pack rule (`ObserveCatastrophe`).
    @Test(
        "catastrophic: disk wipes and root deletes stop in every mode, under their own rule",
        arguments: [
            ("dd if=/dev/zero of=/dev/disk0", "system.disk:dd-device"),
            ("dd if=image.iso of=/dev/disk2 bs=1m", "system.disk:dd-device"),
            ("mkfs.ext4 /dev/sdb1", "system.disk:mkfs"),
            ("wipefs -a /dev/sdb", "system.disk:wipefs"),
            ("diskutil eraseDisk APFS Blank disk2", "system.disk:diskutil-erase"),
            ("diskutil apfs deleteContainer disk3", "system.disk:diskutil-apfs-delete"),
            ("rm -rf /usr", "core.filesystem:rm-rf-root-home"),
            ("rm -rf $HOME", "core.filesystem:rm-rf-root-home"),
            (":(){ :|:& };:", "core.filesystem:fork-bomb"),
        ]
    )
    func catastrophicStopsInEveryMode(command: String, rule: String) async throws {
        let place = try Self.place()
        defer { remove(place.observe); remove(place.enforce) }
        let observed = await Self.verdict(command, home: place.observe, cwd: place.cwd)
        guard case .deny(let deny) = observed.result.decision else {
            Issue.record("\(command): observe must stop it, got \(observed.result.decision)")
            return
        }
        #expect(deny.ruleID.rawValue == rule, "\(command)")
        #expect(observed.stoppedInEveryMode, "\(command)")
        let enforced = await Self.verdict(command, home: place.enforce, cwd: place.cwd)
        #expect(enforced.result.decision == observed.result.decision, "\(command)")
    }

    /// The same delete rules on a path under the root, not the root
    /// itself, are not catastrophic: watched in observe.
    @Test(
        "not catastrophic: a delete under home or /tmp is watched in observe",
        arguments: ["rm -rf ~/project/build", "rm -rf /tmp/rv-watched-dir"]
    )
    func deleteUnderRootIsWatched(command: String) async throws {
        let place = try Self.place()
        defer { remove(place.observe); remove(place.enforce) }
        let observed = await Self.verdict(command, home: place.observe, cwd: place.cwd)
        #expect(observed.result.decision == .allow, "\(command)")
        #expect(observed.stoppedInEveryMode == false, "\(command)")
    }

    /// Review of #674: deleting a host's hook wiring turns rv off for that
    /// agent, so it is rv's own files: stopped in observe.
    @Test(
        "rv's own files: deleting or moving a host's hook directory stops in observe",
        arguments: [
            "rm -rf ~/.claude",
            "rv --version; rm -rf ~/.claude",
            "mv ~/.codex ~/.codex.bak",
            "rm -rf ~/.config/opencode",
        ]
    )
    func hookWiringDirectoryStops(command: String) async throws {
        let place = try Self.place()
        defer { remove(place.observe); remove(place.enforce) }
        let observed = await Self.verdict(command, home: place.observe, cwd: place.cwd)
        #expect(observed.result.decision != .allow, "\(command)")
        #expect(observed.stoppedInObserve, "\(command)")
    }

    @Test(
        "rv's own files: reading or creating beside a hook directory is not stopped",
        arguments: ["ls ~/.claude", "cat ~/.claude/CLAUDE.md", "mkdir -p ~/.config/rv-watched-dir"]
    )
    func hookWiringNeighboursRun(command: String) async throws {
        let place = try Self.place()
        defer { remove(place.observe); remove(place.enforce) }
        let observed = await Self.verdict(command, home: place.observe, cwd: place.cwd)
        #expect(observed.stoppedInObserve == false, "\(command): \(observed.result.decision)")
    }

    @Test("not catastrophic: rm -rf ~/Documents runs under observe (the note says exactly what always stops)")
    func documentsDeleteIsWatched() async throws {
        let place = try Self.place()
        defer { remove(place.observe); remove(place.enforce) }
        let observed = await Self.verdict("rm -rf ~/Documents", home: place.observe, cwd: place.cwd)
        #expect(observed.result.decision == .allow)
        #expect(observed.wouldBe.map { $0.result.decision != .allow } == true)
    }

    @Test("catastrophic: a whole disk device, never /dev/null or a tty", arguments: [
        ("/dev/sda", true), ("/dev/sdb1", true), ("/dev/nvme0n1", true), ("/dev/nvme0n1p2", true),
        ("/dev/disk2", true), ("/dev/rdisk2s1", true), ("/dev/mmcblk0p1", true), ("/dev/vda", true),
        ("/dev/xvda", true), ("/dev/hda", true),
        ("/dev/null", false), ("/dev/zero", false), ("/dev/tty", false), ("/dev/stdout", false),
        ("/dev/disk", false), ("/tmp/sda", false),
    ])
    func diskDevice(path: String, device: Bool) {
        #expect(ObserveCatastrophe.isDiskDevice(path) == device, "\(path)")
    }

    @Test("catastrophic: words that write a disk device, never ones that read it", arguments: [
        ("cat /dev/zero >/dev/sda", true), ("echo x >> /dev/sdb", true), ("dd if=x of=/dev/disk2", true),
        ("sudo shred -n1 /dev/sda", true), ("cp image.img /dev/sdb", true), ("mkfs.ext4 /dev/sdb1", true),
        ("git status; truncate -s0 /dev/nvme0n1", true),
        ("dd if=/dev/sda of=disk.img", false), ("cat /dev/sda > disk.img", false),
        ("echo hi > /dev/null", false), ("cp /dev/sda backup.img", false), ("ls -l /dev/sda", false),
    ])
    func writesDiskDevice(command: String, writes: Bool) {
        #expect(ObserveCatastrophe.writesDiskDevice(command) == writes, "\(command)")
    }

    @Test("catastrophic: the disk set is all system.disk rules the pack ships")
    func diskRulesExist() throws {
        let shipped = Set(dayOneDestructiveRuleIDs(pack: .systemDisk))
        #expect(ObserveCatastrophe.diskRules.isSubset(of: shipped), "\(ObserveCatastrophe.diskRules.subtracting(shipped))")
        let filesystem = Set(dayOneDestructiveRuleIDs(pack: .coreFilesystem))
        #expect(ObserveCatastrophe.rootDeleteRules.isSubset(of: filesystem))
        #expect(filesystem.contains(ObserveCatastrophe.forkBomb))
    }

    /// A catastrophic stop under observe is enforce's own deny, so the
    /// unlock enforce offers works the same: an allow-once grant for that
    /// exact command lets it through (`rv explain`'s Next line is honest).
    @Test("catastrophic: an allow-once grant unlocks it under observe, as in enforce")
    func allowOnceUnlocksCatastrophicStop() async throws {
        let place = try Self.place()
        defer { remove(place.observe); remove(place.enforce) }
        let command = "dd if=/dev/zero of=/dev/disk0"
        for home in [place.observe, place.enforce] {
            let grants = EphemeralAllowOnceTable()
            #expect(await grants.plant(matchingView: MatchingView(command), cwd: place.cwd, codeHash: "c", now: Self.now) == .planted)
            let verdict = await GatedEvaluate().peekVerdict(
                command: ShellCommand(rawValue: command), cwd: place.cwd, home: home,
                grants: grants, now: Self.now, allowlist: { AllowlistSnapshot(entries: []) }
            )
            #expect(verdict.result.decision == .allow)
        }
    }

    // MARK: Stopping rvd (Mac stress run of #674)

    /// Stopping rvd stops in observe only, by design: an observe hook lets
    /// every later call run unchecked while rvd is absent, so observe
    /// floors it. Enforce does not, because there a missing rvd fails
    /// closed: the hook asks or denies (`RV_HOOK_WHEN_DOWN` has no allow
    /// value), and `rv-hook-local` escalates anything it cannot decide to
    /// that same fallback. Pinned here so a change to either side is seen.
    @Test(
        "rvd stop: stopped in observe, evaluated as an allow in enforce (enforce fails closed without rvd)",
        arguments: [
            "pkill rvd",
            "launchctl bootout gui/501/dev.rv.evaluate",
            "rv doctor && pkill rvd",
        ]
    )
    func rvdStopIsObserveOnly(command: String) async throws {
        let place = try Self.place()
        defer { remove(place.observe); remove(place.enforce) }
        let observed = await Self.verdict(command, home: place.observe, cwd: place.cwd)
        #expect(observed.result.decision != .allow, "\(command)")
        #expect(observed.stoppedInObserve, "\(command)")
        // Enforce lets it run, so the words never say "in every mode".
        #expect(observed.stoppedInEveryMode == false, "\(command)")
        let enforced = await Self.verdict(command, home: place.enforce, cwd: place.cwd)
        #expect(enforced.result.decision == .allow, "\(command)")
    }

    // MARK: Secrets (coordination with #668)

    /// No secrets rule is ever a watched class: when #668 lands its
    /// `core.secrets:*` denies, observe can never relabel them watched.
    @Test("secrets: no core.secrets rule is a watched class")
    func secretsAreNeverWatched() {
        for rule in SecretPathCatalog.dayOne.rules {
            let id = SecretPathMatch(rule).ruleID
            #expect(ObserveFloor.isWatchedClass(id) == false, "\(id.rawValue)")
        }
        for pattern in ["env-file", "ssh-private-key", "home-rv-config", "git-hooks", "anything"] {
            #expect(ObserveFloor.isWatchedClass(RuleID(pack: .coreSecrets, pattern: pattern)) == false)
        }
        #expect(ObserveFloor.watchedClasses.allSatisfy { $0.ruleID.pack != .coreSecrets })
    }

    // MARK: Helpers

    /// The destructive rule ids a day-one pack ships, read from its JSON.
    private func dayOneDestructiveRuleIDs(pack: PackID, file: String = #filePath) -> [RuleID] {
        let url = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/RVPacks/Resources/packs/\(pack.rawValue).json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["destructive_patterns"] as? [[String: Any]] else { return [] }
        return rows.compactMap { ($0["name"] as? String).map { RuleID(pack: pack, pattern: $0) } }
    }

    private static func builtin(_ rule: BuiltinRule) -> Deny {
        switch rule {
        case .unresolvedPath: ActionPolicyEngine.Builtin.unresolvedFilesystem
        case .outOfRepoWrite: ActionPolicyEngine.Builtin.outsideRepository
        case .unwrapLimited: ActionPolicyEngine.Builtin.unwrapLimited
        default: Deny(ruleID: rule.ruleID, reason: "")
        }
    }

    private static func denied(_ deny: Deny) -> EvaluationResult {
        EvaluationResult(outcome: .deny(deny, matched: nil))
    }

    private func floorRule(
        _ command: String, result: EvaluationResult, home: HomeDirectory? = nil
    ) -> ObserveFloor.Ruling {
        ObserveFloor.rule(
            result,
            door: .shell(ShellCommand(rawValue: command), store: .gather(home: home, cwd: nil)),
            context: ObserveFloor.Context(home: home, cwd: nil, rvdPIDs: { [] })
        )
    }

    /// An observe home, an enforce home and a repository cwd.
    private static func place() throws -> (observe: HomeDirectory, enforce: HomeDirectory, cwd: WorkingDirectory) {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-watched-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true
        )
        return (
            try guardHome(mode: "observe"), try guardHome(mode: "enforce"),
            try #require(WorkingDirectory(validating: repo.path))
        )
    }

    private static func verdict(_ command: String, home: HomeDirectory, cwd: WorkingDirectory) async -> GatedVerdict {
        await GatedEvaluate().peekVerdict(
            command: ShellCommand(rawValue: command), cwd: cwd, home: home,
            grants: EphemeralAllowOnceTable(), now: now, allowlist: { AllowlistSnapshot(entries: []) }
        )
    }
}

/// `judge.mode` shadow (the default, Chris 2026-11-21): the judge scores
/// and logs, never decides.
@Suite("Judge shadow mode")
struct JudgeShadowModeTests {
    @Test("unset, shadow or unknown judge.mode selects a shadow judge; only live decides")
    func selectionFollowsConfig() throws {
        let cases: [(String, Bool)] = [
            ("{}", true),
            (#"{"judge":{"mode":"shadow"}}"#, true),
            (#"{"judge":{"mode":"bogus"}}"#, true),
            (#"{"judge":{"mode":"live"}}"#, false),
        ]
        for (json, shadow) in cases {
            let config = GuardConfig(jsonData: Data(json.utf8))
            #expect(JudgeRuntime.selection(home: nil, config: config).shadow == shadow, "\(json)")
        }
    }

    /// A blocking judge over a pack-allow: shadow allows and logs the
    /// judge's would-be; live blocks. Pack denies stand either way.
    @Test("shadow: a judge block never decides, and is logged as a would-be")
    func shadowLogsButNeverDecides() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let shadowed = await blockingJudge("brew list", home: home, shadow: true)
        #expect(shadowed.decision == .allow)
        let rows = try judgeLog(home)
        #expect(rows.count == 1)
        #expect(rows.first?["wouldBe"] as? String == "deny")

        let live = await blockingJudge("brew list", home: home, shadow: false)
        #expect(live.decision != .allow)

        let packDeny = await blockingJudge("git reset --hard", home: home, shadow: true)
        guard case .deny(let deny) = packDeny.decision else {
            Issue.record("a pack deny must stand under a shadow judge, got \(packDeny.decision)")
            return
        }
        #expect(deny.ruleID == RuleID(pack: .coreGit, pattern: "reset-hard"))
    }

    /// Review of #674: under observe a shadow judge's block became the
    /// would-be (`core.judge:laya-block`, `wouldBe=deny`), so `rv blocks`
    /// showed a stop enforce never makes. Under shadow the would-be is the
    /// packs-only answer enforce gives; the judge only reaches the log.
    @Test("shadow under observe: the would-be is enforce's packs-only answer; no judge row in rv blocks")
    func shadowObserveWouldBeIsPacksOnly() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let shadowed = await observedBlockingJudge("brew list", home: home, shadow: true)
        #expect(shadowed.result.decision == .allow)
        #expect(shadowed.wouldBe.map { $0.result.decision == .allow } ?? true, "\(String(describing: shadowed.wouldBe))")
        #expect(ledgerRows(home).isEmpty, "\(ledgerRows(home))")
        let rows = try judgeLog(home)
        #expect(rows.count == 1)
        #expect((rows.first?["note"] as? String)?.hasPrefix("shadow") == true, "\(rows)")

        // Live, the same judge block is the would-be, as before.
        let liveHome = try guardHome(mode: "observe")
        defer { remove(liveHome) }
        let live = await observedBlockingJudge("brew list", home: liveHome, shadow: false)
        #expect(live.result.decision == .allow)
        #expect(live.wouldBe.map { $0.result.decision != .allow } == true)
        #expect(ledgerRows(liveHome).count == 1)
    }

    private func observedBlockingJudge(
        _ command: String, home: HomeDirectory, shadow: Bool
    ) async -> (result: EvaluationResult, wouldBe: GatedVerdict.WouldBe?) {
        let block: JudgeRuntime.JudgeRun
        do {
            block = .verdict(try effectVerdict(choice: "block", risk: 1.0))
        } catch {
            Issue.record("verdict: \(error)")
            return (EvaluationResult(outcome: .plain), nil)
        }
        let inputs = EvaluationInputs(
            guardMode: .observe,
            judge: JudgeSelection(
                engine: .ft, bundle: URL(fileURLWithPath: "/nonexistent/rv-fake-bundle", isDirectory: true),
                shadow: shadow
            ),
            store: .gather(home: home, cwd: nil)
        )
        let verdict = await GatedEvaluate(EvaluateSession(), judge: EffectFixedJudge(run: block)).gatedVerdict(
            .apply,
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
            cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Date(timeIntervalSince1970: 1_800_000_000),
            allowlist: { .empty }, host: .hook(.claude), tool: .bash, previewsWouldBe: true, inputs: inputs
        )
        return (verdict.result, verdict.wouldBe)
    }

    private func blockingJudge(_ command: String, home: HomeDirectory, shadow: Bool) async -> EvaluationResult {
        let block: JudgeRuntime.JudgeRun
        do {
            block = .verdict(try effectVerdict(choice: "block", risk: 1.0))
        } catch {
            Issue.record("verdict: \(error)")
            return EvaluationResult(outcome: .plain)
        }
        let inputs = EvaluationInputs(
            guardMode: .enforce,
            judge: JudgeSelection(
                engine: .ft, bundle: URL(fileURLWithPath: "/nonexistent/rv-fake-bundle", isDirectory: true),
                shadow: shadow
            ),
            store: .gather(home: home, cwd: nil)
        )
        return await GatedEvaluate(EvaluateSession(), judge: EffectFixedJudge(run: block)).gated(
            .apply,
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
            cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Date(timeIntervalSince1970: 1_800_000_000),
            allowlist: { .empty }, host: .hook(.claude), tool: .bash, inputs: inputs
        )
    }
}
