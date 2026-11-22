import Foundation
import Testing
import RVDomain
import RVEngine
import RVPolicy
@testable import RVService

/// "Your agents can never leak your keys": an agent's read of a secret file
/// and its switching off of the commit check stop in every mode, as rv's
/// self-protection does. Watch (observe) mode records everything else, but
/// a watched secret read would already have handed the agent the value.
@Suite("Secrets stop in every mode")
struct SecretsEveryModeTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let observe = #"{"guard":{"hosts":{"claude":"observe"}}}"#
    private static let block = #"{"guard":{"hosts":{"claude":"block"}}}"#

    private static func home(_ config: String) throws -> HomeDirectory {
        let home = try guardHome(mode: nil)
        let directory = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try config.write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        return home
    }

    private static func apply(_ command: String, home: HomeDirectory) async -> EvaluationResult {
        await GatedEvaluate().apply(
            command: ShellCommand(rawValue: command), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { .empty }, host: .hook(.claude)
        )
    }

    @Test("observe host: reading a secret file is stopped, not watched", arguments: [
        "cat .env",
        "cat ./.env.local",
        "head -n 3 .env",
        "grep KEY .env",
        "cat ~/.ssh/id_rsa",
        "cat ~/.aws/credentials",
        "cat ~/.config/gh/hosts.yml",
        "cat ~/.codex/auth.json",
        // A secret read an earlier pack deny would hide from the verdict.
        "git reset --hard; cat .env",
        "git reset --hard && cat ~/.ssh/id_ed25519",
        // A secret read in program text the command feeds a shell.
        "bash -c 'cat .env'",
        "echo 'cat .env' | sh",
    ])
    func observeStopsSecretReads(command: String) async throws {
        let home = try Self.home(Self.observe)
        defer { remove(home) }
        let result = await Self.apply(command, home: home)
        #expect(result.decision != .allow, "\(command)")
        #expect(ledgerRows(home).allSatisfy { $0.observed == false }, "\(command)")
    }

    @Test("observe host: everyday commands are still only watched", arguments: [
        "git reset --hard",
        "rm -rf ~/Documents",
    ])
    func observeStillWatchesTheRest(command: String) async throws {
        let home = try Self.home(Self.observe)
        defer { remove(home) }
        let result = await Self.apply(command, home: home)
        #expect(result.decision == .allow, "\(command)")
        #expect(ledgerRows(home).map(\.observed) == [true], "\(command)")
    }

    @Test("observe host: an example env file stays readable", arguments: ["cat .env.example", "ls -la"])
    func observeAllowsExampleFiles(command: String) async throws {
        let home = try Self.home(Self.observe)
        defer { remove(home) }
        #expect(await Self.apply(command, home: home).decision == .allow, "\(command)")
    }

    @Test("file door: Read of a secret file is denied on an observe host", arguments: [
        "/.env", "/project/.env.production", "/.ssh/id_rsa", "/.aws/credentials",
    ])
    func observeFileDoorDeniesSecretReads(suffix: String) throws {
        let home = try Self.home(Self.observe)
        defer { remove(home) }
        let action = FileToolAction(kind: .read, path: FileToolPath(rawValue: home.rawValue + suffix))
        let result = GatedEvaluate().runFile(action, home: home, host: .hook(.claude), now: Self.now)
        guard case .deny(let deny) = result.decision else {
            Issue.record("\(suffix): expected a deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID.pack == .coreSecrets)
        #expect(ledgerRows(home).allSatisfy { $0.observed == false })
    }

    // MARK: S2: the commit check's off switch

    @Test("the commit check's off switch is owner-only on every host", arguments: [
        "git config rv.secretsScan false",
        "git config --global rv.secretsScan false",
        "git -c rv.secretsScan=false commit -m x",
        "echo 'config.ts:generic-secret:3' >> .rv-secrets-ignore",
        #"sed -i 's/$/ # rv-secrets:allow/' config.ts"#,
        "git config -t bool rv.secretsScan false",
        "git config --ty bool rv.secretsScan false",
        "git config --fil .git/config rv.secretsScan false",
        "git config --global core.hooksPath /dev/null",
        "git config --global include.path /tmp/evil",
        "echo rv.secretsScan false | xargs git config",
        "git -c alias.x='!git config rv.secretsScan false' x",
        "chmod -x .git/hooks/pre-commit",
        "rm .git/hooks/pre-commit",
        ": > .git/hooks/pre-commit",
        #"printf '[rv]\n\tsecretsS%san = false\n' c >> .git/config"#,
        // A pack deny in front must not let one allow-once run the switch.
        "git reset --hard && git config rv.secretsScan false",
    ])
    func switchIsOwnerOnly(command: String) async throws {
        for config in [Self.block, Self.observe] {
            let home = try Self.home(config)
            defer { remove(home) }
            let result = await Self.apply(command, home: home)
            guard case .deny(let deny) = result.decision else {
                Issue.record("\(config) \(command): expected a deny, got \(result.decision)")
                continue
            }
            // Writes inside `.git` keep the filesystem rule (protected path,
            // or an unresolved path with no cwd), pinned as well; everything
            // else is the commit check's own stop.
            #expect(
                deny.ruleID == SecretsScanGuard.ruleID || deny.ruleID.pack == BuiltinRule.protectedPathMutation.ruleID.pack,
                "\(config) \(command): \(deny.ruleID)")
            #expect(HookAuthorization.isPinned(result), "\(config) \(command): not pinned")
            #expect(ledgerRows(home).allSatisfy { $0.observed == false }, "\(command)")
        }
    }

    @Test("reading the switch and searching for allow comments stay allowed", arguments: [
        "git config --get rv.secretsScan",
        "grep -rn rv-secrets:allow .",
        "awk '/url/' .git/config",
        "perl -ne 'print if /url/' .git/config",
        #"python3 -c "import configparser" && cat .git/config"#,
        "git config rv.secretsScan true",
        "swift test --filter SecretsScanGuardTests",
        "git add Sources/RVEngine/SecretsScanGuard.swift",
        "sed -n 1,40p Sources/RVEngine/SecretsScanGuard.swift",
        "git commit -m 'guard rv.secretsScan'",
        "find . -name '*SecretsScan*'",
        "git add .rv-secrets-ignore",
    ])
    func readsStayAllowed(command: String) async throws {
        let home = try Self.home(Self.block)
        defer { remove(home) }
        #expect(await Self.apply(command, home: home).decision == .allow, "\(command)")
    }

    @Test("naming the controls is never the pinned stop", arguments: [
        "cat .rv-secrets-ignore | sort",
        // An out-of-repo report stays an ordinary write another rule judges.
        "grep -rn 'rv-secrets:allow' . > /tmp/hits",
        // A commit message is text, not commands (Claude Code's own form).
        """
        git commit -m "$(cat <<'EOF'
        Tidy the hook

        rm .git/hooks/pre-commit
        git config rv.secretsScan false
        EOF
        )"
        """,
        // Without rv's hook, a repository's own hooksPath is the git rules' call.
        "git init /tmp/x && cd /tmp/x && git config core.hooksPath .githooks",
        "grep -n secretsScan .git/config",
        "git log -p -- .rv-secrets-ignore",
    ])
    func namingIsNotThePinnedStop(command: String) async throws {
        for config in [Self.block, Self.observe] {
            let home = try Self.home(config)
            defer { remove(home) }
            let result = await Self.apply(command, home: home)
            if case .deny(let deny) = result.decision {
                #expect(deny.ruleID != SecretsScanGuard.ruleID, "\(config) \(command)")
            }
        }
    }

    @Test("file door: writing the scan's controls is denied, reading them is not", arguments: [
        "/repo/.rv-secrets-ignore", "/repo/.git/config", "/repo/.git/hooks/pre-commit", "/.gitconfig",
    ])
    func fileDoorGuardsScanControls(suffix: String) throws {
        for config in [Self.block, Self.observe] {
            let home = try Self.home(config)
            defer { remove(home) }
            let path = FileToolPath(rawValue: home.rawValue + suffix)
            for kind in [FileToolKind.write, .edit] {
                let result = GatedEvaluate().runFile(
                    FileToolAction(kind: kind, path: path), home: home, host: .hook(.claude), now: Self.now)
                guard case .deny(let deny) = result.decision else {
                    Issue.record("\(config) \(kind) \(suffix): expected a deny, got \(result.decision)")
                    continue
                }
                #expect(deny.ruleID == SecretsScanGuard.ruleID)
            }
            let read = GatedEvaluate().runFile(
                FileToolAction(kind: .read, path: path), home: home, host: .hook(.claude), now: Self.now)
            #expect(read.decision == .allow, "\(config) read \(suffix)")
        }
    }

    // MARK: Hooks skipped or moved, only where rv's hook is installed

    /// Where rv's block is, if anywhere: `.git/hooks`, `.husky` through
    /// core.hooksPath, or the common dir's hooks of a linked worktree.
    private enum HookPlace { case none, gitHooks, husky, linkedWorktree }

    private static func repo(in home: HomeDirectory, hook: HookPlace) throws -> WorkingDirectory {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: home.rawValue).appendingPathComponent("repo")
        let git = root.appendingPathComponent(".git")
        try fm.createDirectory(at: git.appendingPathComponent("hooks"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        let block = "#!/bin/sh\n# >>> rv secrets >>>\nrv secrets hook run || exit $?\n# <<< rv secrets <<<\n"
        switch hook {
        case .none:
            try Data("#!/bin/sh\nnpm run lint\n".utf8).write(to: git.appendingPathComponent("hooks/pre-commit"))
        case .gitHooks:
            try Data(block.utf8).write(to: git.appendingPathComponent("hooks/pre-commit"))
        case .husky:
            try Data("[core]\n\trepositoryformatversion = 0\n\thooksPath = .husky ; set by husky\n".utf8)
                .write(to: git.appendingPathComponent("config"))
            try fm.createDirectory(at: root.appendingPathComponent(".husky"), withIntermediateDirectories: true)
            try Data(block.utf8).write(to: root.appendingPathComponent(".husky/pre-commit"))
        case .linkedWorktree:
            try Data(block.utf8).write(to: git.appendingPathComponent("hooks/pre-commit"))
            let linked = git.appendingPathComponent("worktrees/wt")
            try fm.createDirectory(at: linked, withIntermediateDirectories: true)
            try Data("../..\n".utf8).write(to: linked.appendingPathComponent("commondir"))
            let tree = URL(fileURLWithPath: home.rawValue).appendingPathComponent("wt")
            try fm.createDirectory(at: tree, withIntermediateDirectories: true)
            try Data("gitdir: \(linked.path)\n".utf8).write(to: tree.appendingPathComponent(".git"))
            return try #require(WorkingDirectory(validating: tree.path))
        }
        return try #require(WorkingDirectory(validating: root.path))
    }

    private static func apply(_ command: String, home: HomeDirectory, cwd: WorkingDirectory) async -> EvaluationResult {
        await GatedEvaluate().apply(
            command: ShellCommand(rawValue: command), cwd: cwd, home: home,
            grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { .empty }, host: .hook(.claude)
        )
    }

    @Test("skipping or moving hooks stops where rv's hook is installed", arguments: [
        "git commit --no-verify -m x",
        "git commit -nm x",
        "git config --unset core.hooksPath",
        "git config core.hooksPath /dev/null",
        "git -c alias.ci='commit --no-verify' ci -m x",
        "git config alias.ci 'commit --no-verify'",
        "git commit-tree HEAD^{tree} -m x",
        "HOME=/tmp git commit -m x",
    ])
    func skippingRVHookStops(command: String) async throws {
        for place in [HookPlace.gitHooks, .husky, .linkedWorktree] {
            for config in [Self.block, Self.observe] {
                let home = try Self.home(config)
                defer { remove(home) }
                let cwd = try Self.repo(in: home, hook: place)
                let result = await Self.apply(command, home: home, cwd: cwd)
                guard case .deny(let deny) = result.decision else {
                    Issue.record("\(place) \(config) \(command): expected a deny, got \(result.decision)")
                    continue
                }
                #expect(deny.ruleID == SecretsScanGuard.ruleID)
            }
        }
    }

    @Test("removing or moving rv's hook stops, in a shared hooks dir too", arguments: [
        "rm .husky/pre-commit",
        "rm -rf .husky",
        "chmod -x .husky/pre-commit",
        "cd .husky && : > pre-commit",
        "sh -c 'rm .husky/pre-commit'",
    ])
    func removingRVHookStops(command: String) async throws {
        for config in [Self.block, Self.observe] {
            let home = try Self.home(config)
            defer { remove(home) }
            let cwd = try Self.repo(in: home, hook: .husky)
            let result = await Self.apply(command, home: home, cwd: cwd)
            guard case .deny(let deny) = result.decision else {
                Issue.record("\(config) \(command): expected a deny, got \(result.decision)")
                continue
            }
            #expect(deny.ruleID == SecretsScanGuard.ruleID, "\(config) \(command)")
        }
    }

    @Test("the repository a command acts on is the one probed", arguments: [
        "git -C repo commit -n -m x",
        "cd repo && git commit -n -m x",
        "git --git-dir=repo/.git --work-tree=repo commit -n -m x",
        "git -C repo config --unset core.hooksPath",
    ])
    func targetRepositoryIsProbed(command: String) async throws {
        let home = try Self.home(Self.block)
        defer { remove(home) }
        let repo = try Self.repo(in: home, hook: .gitHooks)
        let parent = try #require(WorkingDirectory(validating: (repo.rawValue as NSString).deletingLastPathComponent))
        let result = await Self.apply(command, home: home, cwd: parent)
        guard case .deny(let deny) = result.decision else {
            Issue.record("\(command): expected a deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == SecretsScanGuard.ruleID, "\(command)")
    }

    @Test("skipping hooks stays allowed in a repository without rv's hook", arguments: [
        "git commit --no-verify -m x",
        "git commit -nm x",
        "git config --unset core.hooksPath",
        "git -c alias.ci='commit --no-verify' ci -m x",
    ])
    func skippingOtherHooksIsAllowed(command: String) async throws {
        let home = try Self.home(Self.block)
        defer { remove(home) }
        let cwd = try Self.repo(in: home, hook: .none)
        #expect(await Self.apply(command, home: home, cwd: cwd).decision == .allow, "\(command)")
    }

    @Test("a plain commit stays allowed where rv's hook is installed")
    func plainCommitAllowed() async throws {
        let home = try Self.home(Self.block)
        defer { remove(home) }
        let cwd = try Self.repo(in: home, hook: .gitHooks)
        #expect(await Self.apply("git commit -m x", home: home, cwd: cwd).decision == .allow)
    }

    @Test("file door: editing a shared hooks dir's pre-commit with rv's block is denied")
    func fileDoorGuardsHuskyHook() throws {
        let home = try Self.home(Self.block)
        defer { remove(home) }
        let cwd = try Self.repo(in: home, hook: .husky)
        let hook = FileToolPath(rawValue: cwd.rawValue + "/.husky/pre-commit")
        let edit = GatedEvaluate().runFile(
            FileToolAction(kind: .edit, path: hook), home: home, cwd: cwd, host: .hook(.claude), now: Self.now)
        guard case .deny(let deny) = edit.decision else {
            Issue.record("expected a deny, got \(edit.decision)")
            return
        }
        #expect(deny.ruleID == SecretsScanGuard.ruleID)
        let read = GatedEvaluate().runFile(
            FileToolAction(kind: .read, path: hook), home: home, cwd: cwd, host: .hook(.claude), now: Self.now)
        #expect(read.decision == .allow)
        let other = GatedEvaluate().runFile(
            FileToolAction(kind: .edit, path: FileToolPath(rawValue: cwd.rawValue + "/.husky/commit-msg")),
            home: home, cwd: cwd, host: .hook(.claude), now: Self.now)
        #expect(other.decision == .allow)
    }

    @Test("core.hooksPath parsing", arguments: [
        ("[core]\n\thooksPath = .husky\n", ".husky"),
        ("[CORE]\n  HOOKSPATH=\"/opt/hooks\" # c\n", "/opt/hooks"),
        ("[core] hooksPath = a\n[core]\nhooksPath = b\n", "b"),
        ("[core \"x\"]\nhooksPath = no\n", nil),
        ("[user]\nhooksPath = no\n", nil),
    ] as [(String, String?)])
    func parsesHooksPath(text: String, expected: String?) {
        #expect(SecretsScanHookProbe.hooksPath(inConfig: text) == expected)
    }
}
