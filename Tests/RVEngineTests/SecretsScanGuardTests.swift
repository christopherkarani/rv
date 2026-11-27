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
        // Hooks moved away for every repository, or another config file pulled in.
        "git config --global core.hooksPath ~/hooks",
        "git config --system core.hooksPath /tmp/hooks",
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
        // Programs xargs and find -exec run.
        "echo rv.secretsScan false | xargs git config",
        "echo false | xargs git config rv.secretsScan",
        "echo 'rv.secretsScan false' | xargs -I{} sh -c 'git config {}'",
        "printf 'rv.secretsScan\\nfalse\\n' | xargs -n2 git config",
        #"find . -maxdepth 0 -exec git config rv.secretsScan false \;"#,
        "A='rv.secretsScan false'; git config $A",
        "git $(echo config) rv.secretsScan false",
        "git -c alias.x='!git config rv.secretsScan false' x",
        // An allow comment written through a heredoc or a pipe.
        "cat >> src/a.ts <<'EOF'\n// rv-secrets:allow\nEOF",
        "tee -a src/a.ts <<EOF\nconst k = 1 // rv-secrets:allow\nEOF",
        "printf '// rv-secrets:allow\\n' | tee -a src/a.ts",
        // A heredoc a shell runs is commands, not data.
        "bash <<'EOF'\ngit config rv.secretsScan false\nEOF",
        "cat <<'EOF' | sh\ngit config rv.secretsScan false\nEOF",
        "bash -c \"$(cat <<'EOF'\ngit config rv.secretsScan false\nEOF\n)\"",
        "x=$(cat <<'EOF'\ngit config rv.secretsScan false\nEOF\n); eval \"$x\"",
        // Text that only looks like a heredoc.
        "echo \"<<EOF\"\ngit config rv.secretsScan false\nEOF",
        "echo $((1<<EOF))\ngit config rv.secretsScan false\nEOF",
        "cat <<EOF\nx\ngit config rv.secretsScan false",
        // An inline program that writes a control.
        "perl -i -pe 's/false/true/' .git/config",
        #"python3 -c "import os; os.remove('.rv-secrets-ignore')""#,
        #"node -e "require('fs').writeFileSync('.rv-secrets-ignore', '')""#,
        #"awk '{print > ".rv-secrets-ignore"}' list.txt"#,
        // Third review: `<<` inside `${…}`, `$[…]`, `$((…))` is no heredoc.
        "cat ${x/<<EOF/} /dev/null\ngit config rv.secretsScan false\nEOF/}",
        "cat $[1<<EOF] /dev/null\ngit config rv.secretsScan false\nEOF]",
        "cat $(( (1<<EOF) )) /dev/null\ngit config rv.secretsScan false\nEOF",
        "echo \"${x:-<<EOF}\"\ngit config rv.secretsScan false\nEOF",
        // A data heredoc a process substitution runs.
        "tee >(sh) <<'EOF'\ngit config rv.secretsScan false\nEOF",
        "cat <<'EOF' > >(sh)\ngit config rv.secretsScan false\nEOF",
        "cat <<'EOF' >(bash)\ngit config rv.secretsScan false\nEOF",
        // The marker plus any write, wherever on the line it is.
        "printf '%s\\n' '// rv-secrets:allow' | cat >> src/a.ts",
        "echo 'k // rv-secrets:allow' | sed -n p >> f",
        "{ echo '// rv-secrets:allow'; } >> f",
        "(echo '// rv-secrets:allow') >> f",
        "cp /dev/stdin f <<'EOF'\nk // rv-secrets:allow\nEOF",
        "cat <<'EOF' | cat >> f\nk // rv-secrets:allow\nEOF",
        "grep -h rv-secrets:allow a.ts | tee -a b.ts",
        "grep -rn rv-secrets:allow . > hits.txt",
        // Interpreter code that names .git/config or .git/hooks is a write.
        #"python3 -c 'print("[rv]\n\tsecretsScan = false", file=open(".git/config","at"))'"#,
        #"perl -e 'open(F, "+<", ".git/config"); seek(F, 0, 2); print F "x"'"#,
        #"perl -pe 'BEGIN{$^I=""}' .git/config"#,
        #"ruby -e 'File.new(".git/config","a+").puts("x")'"#,
        #"python3 -c 'open(".git/hooks/pre-commit","wt").write("")'"#,
        #"python3 -c "print(open('.git/config').read())""#,
        // A user- or machine-wide alias that skips hooks reaches every repository.
        "git config --global alias.ci 'commit --no-verify'",
        "git config --system alias.ci 'commit -nm'",
        "git config --global alias.x '!git commit -n'",
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
        "git config core.hooksPath .githooks",
        "git init /tmp/x && cd /tmp/x && git config core.hooksPath .githooks",
        "git -c alias.ci='commit --no-verify' ci -m x",
        "git commit -m x $EXTRA",
        "HOME=/tmp git commit -m x",
        "git config alias.st status",
        // A commit message is text, not commands (Claude Code's own form).
        """
        git commit -m "$(cat <<'EOF'
        Tidy the hook

        rm .git/hooks/pre-commit
        git config rv.secretsScan false
        echo '// rv-secrets:allow' >> src/a.ts
        EOF
        )"
        """,
        "git commit -m \"$(cat <<'EOF'\nnote: rv-secrets:allow\nEOF\n)\" && echo done > /tmp/log",
        // A search for the marker writes a report, not a marker.
        "grep -rn 'rv-secrets:allow' . > /tmp/hits",
        "rg -n rv-secrets:allow src | tee /tmp/hits",
        // Interpreters that only read git config.
        "awk '/url/' .git/config",
        "perl -ne 'print if /url/' .git/config",
        #"python3 -c "import configparser" && cat .git/config"#,
        "git config --get alias.ci",
        "git config --global alias.lg 'log --oneline'",
        "gh pr create --title t --body \"$(cat <<'EOF'\n## Summary\nrm .git/hooks/pre-commit\ngit config rv.secretsScan false\nEOF\n)\"",
        "git tag -a v1 -m \"$(cat <<'EOF'\nrelease\nrm .git/hooks/pre-commit\nEOF\n)\"",
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
        "git config core.hooksPath /dev/null",
        "git config --local core.hooksPath .githooks",
        "git -c core.hooksPath=/dev/null commit -m x",
        // Aliases that skip hooks or run a shell.
        "git -c alias.ci='commit --no-verify' ci -m x",
        "git -c alias.ci='commit -nm' ci x",
        #"git -c alias.x='!sh -c "git commit -n -m x"' x"#,
        "git config alias.ci 'commit --no-verify'",
        "git config --global alias.lg '!git log --oneline'",
        // Commit programs from another directory, commits no hook sees.
        "git --exec-path=/tmp/x commit -m x",
        "git --exec-path /tmp/x commit -m x",
        "git --exec-path=/tmp/x merge topic",
        "git am 0001-fix.patch",
        "git hash-object -t commit -w --stdin < c.txt",
        "git hash-object --type=commit -w c.txt",
        "git fast-import < stream.fi",
        "cat $[1<<EOF] /dev/null\ngit commit --no-verify -m x\nEOF]",
        "tee >(sh) <<'EOF'\ngit commit --no-verify -m x\nEOF",
        "git --config-env=alias.ci=CI ci",
        // A commit no hook sees, or one whose hook runs with another home or PATH.
        "git commit-tree HEAD^{tree} -m x",
        "HOME=/tmp git commit -m x",
        "XDG_CONFIG_HOME=/tmp/cfg git commit -m x",
        "export PATH=/tmp/bin:$PATH; git commit -m x",
        "env PATH=/tmp/bin git commit -m x",
        // A dynamic word may be `-n`, and xargs's input may be too.
        "git commit -m x $EXTRA",
        "echo -n | xargs git commit -m x",
        "rm -rf .husky",
        "rm .husky/pre-commit",
        "mv .husky /tmp/old",
        "cp /tmp/empty .husky/pre-commit",
        "chmod -x .husky/pre-commit",
    ])
    func weakensWithRVHook(_ command: String) {
        let hook = "/repo/.husky/pre-commit"
        let cwd = WorkingDirectory(validating: "/repo")
        #expect(SecretsScanGuard.weakensScan(ShellCommand(rawValue: command), cwd: cwd) { _ in hook }, "\(command)")
        #expect(SecretsScanGuard.weakensScan(ShellCommand(rawValue: command), cwd: cwd) { _ in nil } == false, "\(command)")
    }

    @Test("the repository each command acts on", arguments: [
        ("git -C repo commit -n", true),
        ("git -C /work/repo commit -n", true),
        ("git -C sub -C ../repo commit -n", true),
        ("cd repo && git commit -n", true),
        ("cd /work/repo; git commit --no-verify", true),
        ("(cd repo && git commit -n)", true),
        ("git --git-dir=repo/.git --work-tree=repo commit -n", true),
        ("git --git-dir repo/.git commit -n", true),
        ("GIT_DIR=repo/.git git commit -n", true),
        ("git -C repo config --unset core.hooksPath", true),
        ("cd repo && git config core.hooksPath /dev/null", true),
        ("rm -rf repo/.husky", true),
        ("cd repo && rm .husky/pre-commit", true),
        ("git commit -n", false),
        ("git -C other commit -n", false),
        ("cd other && git commit -n", false),
        ("git config core.hooksPath /dev/null", false),
        ("rm -rf other/.husky", false),
        // A placeholder target may be any repository.
        (#"find . -maxdepth 1 -exec git -C {} commit -n \;"#, true),
        ("echo repo | xargs -I{} git -C {} commit -n", true),
        ("git -C \"$R\" commit -n", true),
        ("git --git-dir={}/.git commit -n", true),
        // Past the probe cap the repository is unknown.
        ("(cd d1); (cd d2); (cd d3); (cd d4); (cd d5); (cd d6); (cd d7); (cd d8); cd repo; (cd d9); git commit -n", true),
    ])
    func followsTheTargetRepository(_ command: String, weakens: Bool) {
        let cwd = WorkingDirectory(validating: "/work")
        let probe: (String) -> String? = { directory in
            ["/work/repo", "/work/repo/.git", "/work/repo/.husky"].contains(directory)
                ? "/work/repo/.husky/pre-commit" : nil
        }
        #expect(SecretsScanGuard.weakensScan(ShellCommand(rawValue: command), cwd: cwd, installedHook: probe) == weakens,
                "\(command)")
    }

    @Test func noCwdStillPlacesAnAbsoluteTarget() {
        let probe: (String) -> String? = { $0 == "/work/repo" ? "/work/repo/.git/hooks/pre-commit" : nil }
        #expect(SecretsScanGuard.weakensScan(ShellCommand(rawValue: "git -C /work/repo commit -n"), installedHook: probe))
        #expect(SecretsScanGuard.weakensScan(ShellCommand(rawValue: "git -C repo commit -n"), installedHook: probe) == false)
    }

    @Test func probesAreBoundedAndThePastTheCapRepositoryFailsClosed() {
        var asked = 0
        let cds = (0..<40).map { "cd /d\($0)" }.joined(separator: "; ")
        let weakens = SecretsScanGuard.weakensScan(
            ShellCommand(rawValue: cds + "; git commit -n"), cwd: WorkingDirectory(validating: "/work")
        ) { _ in
            asked += 1
            return nil
        }
        #expect(asked <= SecretsScanGuard.maximumProbes)
        #expect(weakens)
    }

    @Test("with rv's hook installed, everyday commits stay allowed", arguments: [
        "git commit -am x",
        "git commit --amend -m x",
        "git commit --amend --no-edit",
        "git commit -F msg.txt",
        "git commit -S -m x",
        "git commit --fixup HEAD",
        "git -c user.name=Dev commit -m x",
        "git commit -m \"$(cat <<'EOF'\nTidy\n\nrm .git/hooks/pre-commit\ngit commit -n\nEOF\n)\"",
        "git tag -a v1 -m \"$(cat <<'EOF'\nrelease notes\nEOF\n)\"",
        "gh pr create --title t --body \"$(cat <<'EOF'\n## Summary\ngit commit --no-verify\nEOF\n)\"",
        "git config --get core.hooksPath",
        "git config --list",
        "awk '/url/' .git/config",
        #"python3 -c "import configparser" && cat .git/config"#,
        "git ls-files -m | xargs git add",
        "npx husky install",
        "npx husky init",
        "lefthook install",
        "git --exec-path",
        "git am --abort",
    ])
    func everydayCommitsWithRVHook(_ command: String) {
        let cwd = WorkingDirectory(validating: "/repo")
        #expect(SecretsScanGuard.weakensScan(ShellCommand(rawValue: command), cwd: cwd) { _ in "/repo/.git/hooks/pre-commit" } == false,
                "\(command)")
    }

    @Test func aCommandTooLargeToEvaluateIsLeftToTheEngine() {
        let huge = "git config rv.secretsScan false; echo " + String(repeating: "a", count: 1_048_576)
        let start = ContinuousClock.now
        #expect(SecretsScanGuard.weakensScan(ShellCommand(rawValue: huge)) == false)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func theProbeRunsOnlyForCommandsThatCouldNeedIt() {
        var asked = 0
        let cwd = WorkingDirectory(validating: "/repo")
        for command in ["ls -la", "npm test", "git status", "cat README.md"] {
            _ = SecretsScanGuard.weakensScan(ShellCommand(rawValue: command), cwd: cwd) { _ in
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
