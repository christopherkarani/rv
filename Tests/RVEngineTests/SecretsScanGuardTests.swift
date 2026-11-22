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
    ]

    @Test(arguments: weakening)
    func weakensTheScan(_ command: String) {
        #expect(SecretsScanGuard.weakensScan(ShellCommand(rawValue: command)), "\(command)")
    }

    @Test(arguments: harmless)
    func leavesReadsAndOtherCommandsAlone(_ command: String) {
        #expect(SecretsScanGuard.weakensScan(ShellCommand(rawValue: command)) == false, "\(command)")
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
}
