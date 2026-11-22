import Testing
import RVDomain
@testable import RVEngine

/// S2: an agent cannot switch off or silence the pre-commit secrets scan.
@Suite("Commit check off switch guard")
struct SecretsScanGuardTests {
    static let weakening: [String] = [
        // The kill switch, every scope and spelling git accepts.
        "git config rv.secretsScan false",
        "git config --local rv.secretsScan false",
        "git config --global rv.secretsScan false",
        "git config --system rv.secretsScan 0",
        "git config --worktree rv.secretsScan no",
        "git config set rv.secretsScan false",
        "git config --replace-all rv.secretsScan off",
        "git config --add rv.secretsScan false",
        "git config --bool rv.secretsScan false",
        "git config -f .git/config rv.secretsScan false",
        "git config RV.SECRETSSCAN false",
        "git config rv.secretsscan false",
        #"git config "rv.secrets"'Scan' false"#,
        #"git config rv.secrets\Scan false"#,
        "git -C /repo config rv.secretsScan false",
        "cd /repo && git config rv.secretsScan false",
        "bash -c 'git config rv.secretsScan false'",
        "sudo git config --system rv.secretsScan false",
        // Per-invocation config reaches the hook through GIT_CONFIG_PARAMETERS.
        "git -c rv.secretsScan=false commit -m x",
        "git -c RV.secretsScan=0 commit -m x",
        "git --config-env=rv.secretsScan=OFF commit -m x",
        "git --config-env rv.secretsScan=OFF commit -m x",
        // A section renamed to rv, or config opened in an editor.
        "git config --rename-section other rv",
        "git config rename-section other rv",
        "git config --edit",
        // Text that writes the switch or the allow paths without git config.
        #"printf '[rv]\n\tsecretsScan = false\n' >> .git/config"#,
        "echo '[rv] secretsScan = false' > ~/.gitconfig",
        "echo 'config.ts:anthropic-api-key:3' >> .rv-secrets-ignore",
        "echo x > .rv-secrets-ignore",
        "> .rv-secrets-ignore",
        "tee -a .rv-secrets-ignore < list.txt",
        "cp /tmp/x .rv-secrets-ignore",
        #"sed -i 's/$/ # rv-secrets:allow/' src/config.ts"#,
        #"perl -pi -e 's/$/ \/\/ rv-secrets:allow/' src/config.ts"#,
        #"python3 -c 'open(".rv-secrets-ignore","a").write("x")'"#,
        "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=rv.secretsScan GIT_CONFIG_VALUE_0=false git commit -m x",
        "cat .rv-secrets-ignore > /tmp/x; mv /tmp/x .rv-secrets-ignore",
        "rv run --secret K -- sh -c 'echo x >> .rv-secrets-ignore'",
        // git's own option spellings: short, attached, unique prefixes.
        "git config -t bool rv.secretsScan false",
        "git config -tbool rv.secretsScan false",
        "git config --ty bool rv.secretsScan false",
        "git config --fil .git/config rv.secretsScan false",
        "git config --glob rv.secretsScan false",
        // An option rv does not know, beside the switch, fails closed.
        "git config --frobnicate rv.secretsScan false",
        // Hooks moved away or another config file pulled in, anywhere.
        "git config core.hooksPath /dev/null",
        "git config --global core.hooksPath ~/hooks",
        "git -c core.hooksPath=/dev/null commit -m x",
        "git config include.path /tmp/evil",
        "git config --global includeIf.gitdir:~/x/.path /tmp/evil",
        "git -c include.path=/tmp/x commit -m x",
        "GIT_CONFIG_GLOBAL=/tmp/evil git commit -m x",
        "export GIT_CONFIG_PARAMETERS=\"'rv.secretsscan'='false'\"",
        // Shell writes of the hooks and config, as the file door denies.
        "chmod -x .git/hooks/pre-commit",
        "rm .git/hooks/pre-commit",
        ": > .git/hooks/pre-commit",
        #"printf '[rv]\n\tsecretsS%san = false\n' c >> .git/config"#,
        "cd /repo/.git && rm hooks/pre-commit",
        "echo '// rv-secrets:allow' >> src/config.ts",
    ]

    static let harmless: [String] = [
        "git config --get rv.secretsScan",
        "git config rv.secretsScan",
        "git config --bool rv.secretsScan",
        "git config get rv.secretsScan",
        "git config --list",
        "git config rv.secretsScan true",
        "git config set rv.secretsScan yes",
        "git config --unset rv.secretsScan",
        "git -C /repo grep -n rv-secrets:allow",
        "git config user.name Dev",
        "git commit -m 'add client'",
        "grep -rn rv-secrets:allow .",
        "rg secretsScan Sources",
        "cat .rv-secrets-ignore",
        "git grep -n rv-secrets:allow",
        "git log -S secretsScan",
        "grep -c rv-secrets:allow src/a.ts 2>/dev/null",
        "rv explain 'git config rv.secretsScan false'",
        "ls -la",
        "npm test",
        // Naming the controls is not touching them.
        "swift test --filter SecretsScanGuardTests",
        "git add Sources/RVEngine/SecretsScanGuard.swift",
        "sed -n 1,40p Sources/RVEngine/SecretsScanGuard.swift",
        "git commit -m 'guard rv.secretsScan'",
        "find . -name '*SecretsScan*'",
        "git add .rv-secrets-ignore",
        "cat .rv-secrets-ignore | sort",
        "git config --get-regexp core",
        "git -c core.pager=cat log",
        "GIT_CONFIG_GLOBAL=/dev/null git status",
        "chmod +x scripts/run.sh",
        "echo hi > notes.txt",
        "python3 -m pytest tests",
        // Without rv's hook, skipping or moving hooks is the repository's own business.
        "git commit -n -m x",
        "git config --unset core.hooksPath",
        "rm -rf .husky",
    ]

    @Test(arguments: weakening)
    func weakensTheScan(_ command: String) {
        #expect(SecretsScanGuard.weakensScan(ShellCommand(rawValue: command)), "\(command)")
    }

    @Test(arguments: harmless)
    func leavesReadsAndOtherCommandsAlone(_ command: String) {
        #expect(SecretsScanGuard.weakensScan(ShellCommand(rawValue: command)) == false, "\(command)")
    }

    @Test("with rv's hook installed", arguments: [
        "git commit -n -m x",
        "git commit --no-verify -m x",
        "git config --unset core.hooksPath",
        "rm -rf .husky",
        "rm .husky/pre-commit",
        "mv .husky /tmp/old",
        "cp /tmp/empty .husky/pre-commit",
        "chmod -x .husky/pre-commit",
    ])
    func weakensWithRVHook(_ command: String) {
        let hook = "/repo/.husky/pre-commit"
        let cwd = WorkingDirectory(validating: "/repo")
        #expect(SecretsScanGuard.weakensScan(ShellCommand(rawValue: command), cwd: cwd) { hook }, "\(command)")
        #expect(SecretsScanGuard.weakensScan(ShellCommand(rawValue: command), cwd: cwd) { nil } == false, "\(command)")
    }

    @Test func theProbeRunsOnlyForCommandsThatCouldNeedIt() {
        var asked = 0
        let cwd = WorkingDirectory(validating: "/repo")
        for command in ["ls -la", "npm test", "git status", "cat README.md"] {
            _ = SecretsScanGuard.weakensScan(ShellCommand(rawValue: command), cwd: cwd) {
                asked += 1
                return "/repo/.git/hooks/pre-commit"
            }
        }
        #expect(asked == 0)
    }

    @Test func foldPinsTheSwitchBehindAPackDeny() {
        let command = "git reset --hard && git config rv.secretsScan false"
        let resetHard = RuleID(pack: .coreGit, pattern: "reset-hard")
        var matched = SecretsScanGuard.match(searchText: command)
        matched.ruleID = resetHard
        let denied = EvaluationResult(
            outcome: .deny(Deny(ruleID: resetHard, reason: "x"), matched: matched),
            matchingView: MatchingView(command)
        )
        let folded = SecretPathDecider.dayOne.fold(denied, command: ShellCommand(rawValue: command))
        guard case .deny(let deny, _) = folded.outcome else {
            Issue.record("expected a deny, got \(folded.outcome)")
            return
        }
        #expect(deny.ruleID == SecretsScanGuard.ruleID)
    }

    @Test func foldDeniesAnAllowedSwitchAsCoreSecrets() {
        let command = "git config rv.secretsScan false"
        let allowed = EvaluationResult(outcome: .plain, matchingView: MatchingView(command))
        let folded = SecretPathDecider.dayOne.fold(allowed, command: ShellCommand(rawValue: command))
        guard case .deny(let deny, _) = folded.outcome else {
            Issue.record("expected a deny, got \(folded.outcome)")
            return
        }
        #expect(deny.ruleID == RuleID(pack: .coreSecrets, pattern: "secrets-scan"))
        #expect(deny.reason.hasPrefix("Only the owner can switch off or silence the commit check."))
        #expect(deny.reason.contains("rv secrets set NAME"))
    }

    @Test("file door: the ignore file, git config and hooks, the global git config", arguments: [
        "/repo/.rv-secrets-ignore",
        "/repo/sub/.RV-SECRETS-IGNORE",
        "/repo/.git/config",
        "/repo/.git/config.worktree",
        "/repo/.git/hooks/pre-commit",
        "/repo/.git/hooks/sub/x",
        "/home/me/.gitconfig",
        "/home/me/.config/git/config",
        ".git/config",
    ])
    func protectsScanFiles(_ path: String) {
        #expect(SecretsScanGuard.protectsFile(path, home: "/home/me"), "\(path)")
    }

    @Test("file door: ordinary files stay writable", arguments: [
        "/repo/src/config.ts",
        "/repo/.gitignore",
        "/repo/.github/workflows/ci.yml",
        "/repo/config",
        "/home/me/.config/other/config",
        "/repo/.git/info/exclude",
    ])
    func leavesOtherFilesAlone(_ path: String) {
        #expect(SecretsScanGuard.protectsFile(path, home: "/home/me") == false, "\(path)")
    }

    @Test("git commit that skips hooks", arguments: [
        "git commit --no-verify -m x",
        "git commit -n -m x",
        "git commit -nm x",
        "git commit -anm x",
        "git commit -m x -n",
        "git commit --no-ver -m x",
        "git -C /repo commit --no-verify",
        "cd /repo && git commit -n",
        "bash -c 'git commit -n -m x'",
        "git commit $FLAGS -m x",
        "git commit -mfixm -n",
    ])
    func skipsCommitHook(_ command: String) {
        #expect(SecretsScanGuard.skipsCommitHook(ShellCommand(rawValue: command)), "\(command)")
    }

    @Test("git commit that runs hooks", arguments: [
        "git commit -m x",
        "git commit -m 'skip -n later'",
        "git commit -m -n",
        "git commit -uno -m x",
        "git commit --amend --no-edit",
        "git commit -F msg.txt",
        "git log -n 3",
        "git merge --no-verify topic",
        "echo git commit -n",
    ])
    func runsCommitHook(_ command: String) {
        #expect(SecretsScanGuard.skipsCommitHook(ShellCommand(rawValue: command)) == false, "\(command)")
    }

    @Test("git config that moves hooks", arguments: [
        "git config --unset core.hooksPath",
        "git config --unset-all core.hooksPath",
        "git config unset core.hooksPath",
        "git config core.hooksPath /tmp/hooks",
        "git config --local core.hooksPath .git/hooks",
        "git config --remove-section core",
        "git config --rename-section core old",
        "git config --unse core.hooksPath",
        "git config --frobnicate core.hooksPath",
    ])
    func movesHooksPath(_ command: String) {
        #expect(SecretsScanGuard.movesHooksPath(ShellCommand(rawValue: command)), "\(command)")
    }

    @Test("git config that leaves hooks alone", arguments: [
        "git config --get core.hooksPath",
        "git config core.hooksPath",
        "git config core.editor vim",
        "git config --unset core.editor",
        "git config --remove-section alias",
    ])
    func leavesHooksPath(_ command: String) {
        #expect(SecretsScanGuard.movesHooksPath(ShellCommand(rawValue: command)) == false, "\(command)")
    }
}
