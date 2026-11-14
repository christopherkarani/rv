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
    /// configured the same commands allow.
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
        "echo .mcp.json | python3 edit.py",
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
