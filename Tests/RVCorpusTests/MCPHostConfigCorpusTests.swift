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
        facts: [
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
        ],
        mcpHostConfigGuard: guarded
            ? MCPHostConfigGuard(resolvedAliases: [repo + "/dotfiles/claude.json"])
            : nil
    )
    return evaluateWithSemantics(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: harness.packs,
        engine: harness.engine,
        compiled: harness.compiled,
        workingDirectory: WorkingDirectory(validating: repo),
        filesystemProbe: { _ in .probed(context) }
    )
}
