import Foundation
import Testing
import RVDomain
import RVEngine

/// Host MCP config writes while rv's MCP gateway is in use
/// (`MCPHostConfigPaths`). The door runs from a repository under an isolated
/// home, so a write to a project config is inside the repository and only
/// the MCP guard stands between it and an allow.
@Suite("MCP host config corpus")
struct MCPHostConfigCorpusTests {
    static let home = "/isolated-home"
    static let repo = "/isolated-home/work/repo"

    @Test func denyRowsAreDeniedWhileTheGatewayIsInUse() throws {
        let harness = try StressHarness.dayOne()
        let rows = try loadStressCorpus("mcp-host-config.json").filter { $0.expected == "deny" }
        #expect(rows.count >= 30)
        for row in rows {
            guard let command = row.command else { continue }
            let result = door(harness, command, guarded: true)
            guard case .deny = result.decision else {
                Issue.record("\(row.id) must deny, got \(describeDecision(result)): \(command)")
                continue
            }
        }
    }

    /// Rows an earlier stage judges indeterminate before the guard runs
    /// (each row's `note` says which, `reason_contains` pins the reason): so
    /// with the guard on or off.
    @Test func indeterminateRowsStayIndeterminateWithOrWithoutTheGuard() throws {
        let harness = try StressHarness.dayOne()
        let rows = try loadStressCorpus("mcp-host-config.json").filter { $0.expected == "indeterminate" }
        #expect(rows.isEmpty == false)
        for row in rows {
            guard let command = row.command else { continue }
            guard let expected = row.reasonContains else {
                Issue.record("\(row.id) must pin its reason in reason_contains")
                continue
            }
            for guarded in [true, false] {
                let result = door(harness, command, guarded: guarded)
                guard case .indeterminate(let reason) = result.decision else {
                    Issue.record("\(row.id) must be indeterminate, got \(describeDecision(result)): \(command)")
                    continue
                }
                #expect(reason.rawValue == expected, "\(row.id) guarded: \(guarded)")
            }
        }
    }

    @Test func allowRowsStayAllowedWhileTheGatewayIsInUse() throws {
        let harness = try StressHarness.dayOne()
        let rows = try loadStressCorpus("mcp-host-config.json").filter { $0.expected == "allow" }
        #expect(rows.isEmpty == false)
        for row in rows {
            guard let command = row.command else { continue }
            let result = door(harness, command, guarded: true)
            if result.decision != .allow {
                Issue.record("\(row.id) must allow, got \(describeDecision(result)): \(command)")
            }
        }
    }

    /// In-repository writes that only the MCP guard denies: the guard owns
    /// the verdict, an owner can approve it (not pinned), and with no gateway
    /// configured the same commands allow. A name piped to `python3 x.py`
    /// is not one of them: the unwrap stage pins a deny on it
    /// (`builtin.action:unwrap-limited`) with or without the guard, and its
    /// corpus row (`mcp.deny.review3.echo-python`) still checks the deny; so
    /// the stdin row is `perl -ne`.
    @Test("in-repository config writes are core.mcp and unlockable", arguments: [
        "echo '{\"mcpServers\":{}}' > .mcp.json",
        "printf '{}' | tee .cursor/mcp.json",
        "sed -i 's/a/b/' .mcp.json",
        "mv evil.json .vscode/",
        "cp /tmp/evil/.mcp.json ./",
        "sed -i 's/a/b/' dotfiles/claude.json",
        "echo '{}' > team-link",
        "node -e \"require('fs').writeFileSync('.mcp.json', '{}')\"",
        "claude mcp add evil -- npx evil-mcp",
        "mv .mcp.json backup.json",
        "cp evil.json .mcp.json",
        "cp .mcp.json backup",
        "cp -r evil .cursor",
        "claude plugin marketplace add evil/market",
        "cp evil.json mcp.json -v",
        "echo .cursor/mcp.json | perl -ne 'print'",
        "python3 edit.py .MCP.JSON",
    ])
    func guardOwnsInRepositoryWrites(command: String) throws {
        let harness = try StressHarness.dayOne()
        let guarded = door(harness, command, guarded: true)
        guard case .deny(let deny) = guarded.decision else {
            Issue.record("\(command) must deny, got \(describeDecision(guarded))")
            return
        }
        #expect(deny.ruleID == MCPHostConfigPaths.ruleID, "\(command)")
        #expect(HookAuthorization.isPinned(guarded) == false, "\(command)")
        #expect(
            HookAuthorization.project(result: guarded, cwd: WorkingDirectory(validating: Self.repo)) == .ask,
            "\(command)")
        let open = door(harness, command, guarded: false)
        #expect(open.decision == .allow, "\(command) without a gateway: \(describeDecision(open))")
    }

    /// The pin door and an unprobed world never carry the guard.
    @Test func unprobedDoorIgnoresTheGuard() throws {
        let harness = try StressHarness.dayOne()
        #expect(harness.door("sed -i 's/a/b/' .mcp.json").decision == .allow)
    }

    /// The service attaches the guard through `attachingMCPHostConfigGuard`.
    /// Should the live probe ever answer `.unprobed`, the guard stays: a
    /// probed world with no working directory, where a guarded name asks.
    @Test func attachedGuardSurvivesAnUnprobedWorld() throws {
        let harness = try StressHarness.dayOne()
        let home = HomePath(validating: Self.home)
        #expect(attachingMCPHostConfigGuard(nil, to: .unprobed, homeDirectory: home) == .unprobed)
        let world = attachingMCPHostConfigGuard(MCPHostConfigGuard(), to: .unprobed, homeDirectory: home)
        guard case .probed(let context) = world else {
            Issue.record("an attached guard must keep a probed world, got \(world)")
            return
        }
        #expect(context.mcpHostConfigGuard != nil)
        #expect(context.workingDirectory == nil)
        for command in [
            "cat .mcp.json", "jq . ~/.claude.json", "claude mcp add evil -- evil-mcp",
            "npx @anthropic-ai/claude-code mcp add evil -- evil-mcp", "sed -i 's/a/b/' .mcp.json",
            "cp ~/.claude.json backup.json",
        ] {
            let result = evaluate(harness, command, world: world)
            #expect(result.decision != .allow, "\(command): \(describeDecision(result))")
        }
        #expect(evaluate(harness, "echo hi", world: world).decision == .allow)
    }

    /// Guard off: a world the guard was never attached to and one built
    /// without it judge alike, the context encodes as it did before the
    /// guard existed, and argv is unchanged by the `assignments` the guard
    /// alone reads.
    @Test("guard off leaves the verdict unchanged", arguments: ordinaryCommands)
    func guardOffVerdictsMatchAContextThatNeverHadTheGuard(command: String) throws {
        let harness = try StressHarness.dayOne()
        let never = FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: Self.repo),
            repositoryRoot: RepositoryRoot(validating: Self.repo),
            homeDirectory: HomePath(validating: Self.home),
            facts: corpusFacts
        )
        let expected = evaluate(harness, command, world: .probed(never))
        let off = attachingMCPHostConfigGuard(nil, to: .probed(never), homeDirectory: never.homeDirectory)
        #expect(evaluate(harness, command, world: off) == expected, "\(command)")
        #expect(door(harness, command, guarded: false) == expected, "\(command)")
        let encoded = try JSONEncoder().encode(never)
        #expect(String(decoding: encoded, as: UTF8.self).contains("mcpHostConfigGuard") == false)
        let decoded = try JSONDecoder().decode(FilesystemAnalysisContext.self, from: encoded)
        #expect(evaluate(harness, command, world: .probed(decoded)) == expected, "\(command)")
        #expect(
            evaluate(harness, command, world: attachingMCPHostConfigGuard(nil, to: .unprobed, homeDirectory: nil))
                == evaluate(harness, command, world: .unprobed),
            "\(command)")
    }

    /// Assignments stay out of argv, inherited through `sh -c` and `eval`.
    @Test func assignmentsDoNotChangeLaunchedArgv() {
        #expect(launchedCommands("X=1 env Y=2 less f") == [["less", "f"]])
        #expect(launchedCommands("A=1 sh -c 'B=2 cat x'") == [["cat", "x"]])
        #expect(launchedCommands("A=1 eval 'cat x'") == [["cat", "x"], ["eval", "cat x"]])
        #expect(launchedCommands("GIT_PAGER=cat git log -p") == [["git", "log", "-p"]])
    }

    /// Through the product door, commands that spend the guard's text budget
    /// ask (`MCPHostCLITextTests.guardAsksWhenItsBudgetRunsOut` and
    /// `guardAsksPastTheDepthCap` assert the read and depth caps by counter).
    /// The time bound only catches a hang.
    @Test func carriedTextReadsAreBounded() throws {
        let harness = try StressHarness.dayOne()
        var nested = "watch xmcp end"
        for _ in 0..<12 { nested = "watch xmcp$(" + nested + ")" }
        let many = "echo " + (0..<600).map { "'xmcp a\($0)'" }.joined(separator: " ") + " | sh"
        for command in [nested, many] {
            let start = ContinuousClock.now
            let result = door(harness, command, guarded: true)
            #expect(result.decision != .allow, "\(command.prefix(80))")
            #expect(ContinuousClock.now - start < .seconds(600), "\(command.prefix(80))")
        }
    }

    /// Through the product door, a host mutation hidden by quoting the shell
    /// tokenizer misreads (an escaped quote or blank, zsh `=(…)` or `=cmd`)
    /// does not allow while the gateway is in use.
    @Test("misread quoting does not hide a host mutation", arguments: [
        "watch \"sh -c \\\"claude mcp add evil -- x\\\"\"",
        "watch 'sh -c '\\''claude mcp add evil -- x'\\'''",
        "watch claude\\ mcp\\ add\\ evil -- x",
        "cat =(claude mcp add evil -- x)",
        "=claude mcp add evil -- x",
    ])
    func misreadQuotingDoesNotHideAHostMutation(command: String) throws {
        let harness = try StressHarness.dayOne()
        let result = door(harness, command, guarded: true)
        #expect(result.decision != .allow, "\(command): \(describeDecision(result))")
    }

    /// A long quoted argument is judged by what it names, not its size: one
    /// past the guard's per-text cap with no host word judges as with the
    /// guard off; the same text naming a host mutation does not allow.
    @Test func longTextIsJudgedByWhatItNames() throws {
        let harness = try StressHarness.dayOne()
        let words = (0..<5_000).map { "w\($0)" }
        let plain = "grep '" + words.joined(separator: " ") + "' notes.txt"
        #expect(door(harness, plain, guarded: true).decision == door(harness, plain, guarded: false).decision)
        let named = "grep '" + (words + ["claude mcp add x -- y"]).joined(separator: " ") + "' notes.txt"
        #expect(door(harness, named, guarded: true).decision != .allow)
    }

    /// With the gateway in use, commands that name no guarded file and run
    /// no host MCP CLI judge exactly as with it off: no ask pattern keys on
    /// a bare word like `mcp`, `install` or a host name used as data.
    @Test("guard on does not touch commands that name no host config", arguments: [
        "make -C mcp install", "pnpm --filter mcp install", "npm --prefix mcp install lodash",
        "uv add mcp", "pip install 'mcp[cli]'", "git checkout -b add-mcp-support",
        "git commit -m 'add mcp install docs'", "grep -rn claude \"$DIR\"", "watch -n 5 'npm test'",
        "claude -p \"fix the failing test in $FILE\"", "claude --version", "codex exec 'run the tests'",
        "npm install -D typescript", "cp a.txt b.txt", "cp -r src dst", "mv old.txt new.txt",
        "ls mcp", "cat mcp/README.md", "less +F build.log", "git grep -n TODO",
        "npm config set registry https://registry.example", "git config --get user.email",
        "rsync -av src/ dst/ --delete", "pnpm exec vitest run", "deno run -A main.ts",
        "npx github:owner/some-tool --help", "echo 'npm test' | sh", "cd tools/gemini-cli-docs",
        "git tag -a v1 -m 'mcp install notes'", "grep -n 'mcp install' README.md",
        "echo 'remember to mcp install later'", "grep mcp install notes.txt",
        "gh pr create --title 'mcp install docs' --body 'run mcp install srv'",
        "make --directory mcp install", "npm -w mcp install lodash", "bun --cwd mcp install",
        "git commit -m \"fix \\\"mcp install\\\" docs\"",
        // Brace, glob and dynamic look-alikes that name no host and no `mcp`.
        "ls *.md", "cp {a,b}.txt dst/", "make install", "echo ${HOME}",
        "npm install {lodash,react}", "git add src/*.swift",
        // A dynamic word or `$IFS` with no host word and no stem.
        "npm install $PKG", "echo $IFS", "make $TARGET install",
        // Spellings where nothing runs them, or that cannot be a host word.
        "grep -rn claude *", "rg codex *", "grep -rn claude * | head", "tr '[:upper:]' '[:lower:]'",
        "claude -p \"explain function f() { ... }\"", "codex exec \"fix {x} in ../src\"",
        "touch f{1..100}", "mkdir -p src/{a,b,c}", "ls *", "npm install np{l..m}",
    ])
    func guardDoesNotTouchUnrelatedCommands(command: String) throws {
        let harness = try StressHarness.dayOne()
        #expect(
            door(harness, command, guarded: true).decision == door(harness, command, guarded: false).decision,
            "\(command)")
    }
}

/// Ordinary shapes for the guard-off check: copies, moves, git, npx, the
/// host CLIs, environment assignments, with and without guarded names.
private let ordinaryCommands = [
    "cp a.txt b.txt", "cp -r src dst", "cp ~/.claude.json backup.json", "cp evil.json .mcp.json",
    "cp a b -f", "cp -- a b", "mv old.txt new.txt", "mv evil.json .vscode/", "ln -sf a b",
    "git status", "git diff .mcp.json", "git commit -m update", "git -c core.pager=cat log",
    "git grep -O mcpServers", "git log --output=out.txt", "npx prettier --write .",
    "npx @anthropic-ai/claude-code mcp add evil -- x", "claude mcp add evil -- x", "claude mcp list",
    "claude \"$@\"", "C=claude; $C mcp add evil x", "uv run mcp install server.py",
    "FOO=1 make test", "LESSOPEN='|x %s' less .mcp.json", "GIT_PAGER=cat git log -p",
    "PATH=/tmp/bin:$PATH cp a b", "A=1 sh -c 'B=2 cat .mcp.json'", "echo .mcp.json | python3 x.py",
    "less '+!sh x' .mcp.json", "cat a > .mcp.json", "sed -i 's/a/b/' .mcp.json",
]

private let corpusFacts: [FilesystemPathFact] = {
    let repo = MCPHostConfigCorpusTests.repo
    return [
        FilesystemPathFact(
            apparent: "notes-link", canonical: "/isolated-home/.claude.json",
            followedSymlink: true, resolution: .resolved),
        FilesystemPathFact(
            apparent: "team-link", canonical: repo + "/.mcp.json",
            followedSymlink: true, resolution: .resolved),
        FilesystemPathFact(apparent: "backup", canonical: repo + "/backup", resolution: .resolved),
        FilesystemPathFact(apparent: "backup.json", canonical: repo + "/backup.json", resolution: .lexical),
        FilesystemPathFact(apparent: "mcp.json.bak", canonical: repo + "/mcp.json.bak", resolution: .lexical),
        // A directory named `-v` that links to `~/.cursor`: BSD `cp a b -v` copies into it.
        FilesystemPathFact(
            apparent: "-v", canonical: "/isolated-home/.cursor", followedSymlink: true, resolution: .resolved),
    ]
}()

private func evaluate(_ harness: StressHarness, _ command: String, world: FilesystemAnalysisWorld) -> EvaluationResult {
    evaluateWithSemantics(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: harness.packs,
        engine: harness.engine,
        compiled: harness.compiled,
        workingDirectory: WorkingDirectory(validating: MCPHostConfigCorpusTests.repo),
        filesystemProbe: { _ in world }
    )
}

/// Product door from `repo` under an isolated home, with the guard on when
/// `guarded`. `notes-link` is a symlink to `~/.claude.json`, `team-link`
/// one to the repository's `.mcp.json`, `backup` an existing directory,
/// `backup.json` and `mcp.json.bak` missing files (`elsewhere` is unprobed),
/// `-v` a directory symlink to `~/.cursor`, and
/// `dotfiles/claude.json` is the resolved target of a guarded file.
private func door(_ harness: StressHarness, _ command: String, guarded: Bool) -> EvaluationResult {
    let repo = MCPHostConfigCorpusTests.repo
    let context = FilesystemAnalysisContext(
        workingDirectory: WorkingDirectory(validating: repo),
        repositoryRoot: RepositoryRoot(validating: repo),
        homeDirectory: HomePath(validating: MCPHostConfigCorpusTests.home),
        facts: corpusFacts,
        mcpHostConfigGuard: guarded
            ? MCPHostConfigGuard(resolvedAliases: [repo + "/dotfiles/claude.json"])
            : nil
    )
    return evaluate(harness, command, world: .probed(context))
}
