import Foundation
import Testing
@testable import RVMCP

@Suite("MCPRedaction")
struct MCPRedactionTests {
    @Test func masksCredentialArgsButKeepsPackages() {
        let result = MCPRedaction.args([
            "-y", "@upstash/context7-mcp", "--api-key", "ctx7sk-00000000-1111-2222-3333-444444444444",
            "--token=abc", "chrome-devtools-mcp@latest", "/Users/me/server.mjs", "--port", "8080",
        ])
        #expect(result.shown == [
            "-y", "@upstash/context7-mcp", "--api-key", "<redacted>", "--token=<redacted>",
            "chrome-devtools-mcp@latest", "/Users/me/server.mjs", "--port", "8080",
        ])
        #expect(result.credentials == ["--api-key", "--token"])
    }

    @Test func masksBareTokensAndURLSecrets() {
        let bare = MCPRedaction.args(["ghp_abcdefghijklmnopqrstuvwxyz0123456789", "server-sequential-thinking"])
        #expect(bare.shown == ["<redacted>", "server-sequential-thinking"])
        #expect(bare.credentials == ["argument 1"])

        #expect(MCPRedaction.url("https://huggingface.co/mcp?login") == ("https://huggingface.co/…", false))
        #expect(MCPRedaction.url("https://mcp.stripe.com") == ("https://mcp.stripe.com", false))
        #expect(MCPRedaction.url("https://x.dev/mcp?api_key=zzz").leaked)
        #expect(MCPRedaction.url("https://user:pw@x.dev/").leaked)
        #expect(MCPRedaction.url("https://x.dev/k/sk-proj-abcdefghijklmnop1234").leaked)
    }

    @Test func literalCredentialsIgnoreReferences() {
        let found = MCPRedaction.literalCredentials([
            "GITHUB_TOKEN": "ghp_live", "API_KEY": "${API_KEY}", "OTHER_KEY": "{env:OTHER}",
            "LOG_LEVEL": "debug", "ENDPOINT": "sk-abcdefghijklmnopqrstu", "EMPTY_TOKEN": "",
        ])
        #expect(found == ["ENDPOINT", "GITHUB_TOKEN"])
    }

    @Test func secretNamesAreWordBased() {
        #expect(MCPRedaction.isSecretName("GITHUB_PERSONAL_ACCESS_TOKEN"))
        #expect(MCPRedaction.isSecretName("api-key"))
        #expect(MCPRedaction.isSecretName("Authorization"))
        #expect(MCPRedaction.isSecretName("MONKEY_PATH") == false)
        #expect(MCPRedaction.isSecretName("KEYBOARD") == false)
    }
}

@Suite("MCPInventory")
struct MCPInventoryTests {
    final class FakeHome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-home-\(UUID().uuidString)")
        var home: URL { root.appendingPathComponent("home") }
        var project: URL { root.appendingPathComponent("project") }

        func write(_ relative: String, under base: URL? = nil, _ text: String) throws {
            let url = (base ?? home).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func populated() throws -> FakeHome {
        let fake = FakeHome()
        let projectPath = fake.project.standardizedFileURL.path
        try fake.write(".claude.json", """
            {"numStartups": 3, "mcpServers": {"wax": {"type": "stdio", "command": "wax-mcp", "args": [], "env": {"WAX_TOKEN": "secretvalue"}}},
             "projects": {"\(projectPath)": {"mcpServers": {"local-one": {"command": "node", "args": ["x.js"]}}}}}
            """)
        try fake.write(".cursor/mcp.json", #"{"mcpServers": {"github": {"command": "/usr/local/bin/rv", "args": ["mcp", "serve", "--server", "github"]}}}"#)
        try fake.write(".codex/config.toml", MiniTOMLTests.codexLike)
        try fake.write(".config/opencode/opencode.json", """
            // opencode allows comments
            {"mcp": {"oc": {"type": "local", "command": ["bun", "run", "srv.ts"], "environment": {"K": "v"}, "enabled": false},
                     "remote": {"type": "remote", "url": "https://mcp.example.com/sse?token=abcdefghijklmnopqrstuvwx1234"},},}
            """)
        try fake.write(".gemini/settings.json", #"{"mcpServers": {"MCP_DOCKER": {"command": "docker", "args": ["mcp", "gateway", "run"]}, "hosted": {"httpUrl": "https://g.example.com/mcp"}}}"#)
        try fake.write(".codeium/windsurf/mcp_config.json", #"{"mcpServers": {"filesystem": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/"]}}}"#)
        try fake.write(".gemini/antigravity/mcp_config.json", "{not json")
        try fake.write(".mcp.json", under: fake.project, #"{"mcpServers": {"team": {"command": "uvx", "args": ["team-mcp"]}}}"#)
        try fake.write(".vscode/mcp.json", under: fake.project, #"{"servers": {"vs": {"type": "stdio", "command": "node", "args": ["v.js"]}}, /* c */ }"#)
        return fake
    }

    @Test func discoversEveryHostShape() throws {
        let fake = try populated()
        let inventory = MCPInventory.discover(home: fake.home, project: fake.project, environment: [:])
        let names = Set(inventory.entries.map { "\($0.host.rawValue):\($0.name)" })
        #expect(names == [
            "claude-code:wax", "claude-code:local-one", "claude-code:team", "cursor:github",
            "codex:context7", "codex:stripe", "codex:node", "opencode:oc", "opencode:remote",
            "gemini:MCP_DOCKER", "gemini:hosted", "windsurf:filesystem", "vscode:vs",
        ])
        #expect(inventory.problems.count == 1)
        #expect(inventory.problems.first?.path.hasSuffix("antigravity/mcp_config.json") == true)

        let local = try #require(inventory.entries.first { $0.name == "local-one" })
        #expect(local.scope == .project(fake.project.standardizedFileURL.path))
        let oc = try #require(inventory.entries.first { $0.name == "oc" })
        #expect(oc.transport == .stdio(command: "bun", args: ["run", "srv.ts"]))
        #expect(oc.isDisabled)
        let node = try #require(inventory.entries.first { $0.name == "node" })
        #expect(node.environment == ["A": "1", "B.C": "two", "D": "é\t"])
        #expect(inventory.entries.first { $0.name == "github" }?.governedServer == "github")
    }

    @Test func codexHomeOverride() throws {
        let fake = FakeHome()
        try fake.write("alt/config.toml", "[mcp_servers.x]\ncommand = \"x\"\n")
        let codexHome = fake.home.appendingPathComponent("alt").path
        let inventory = MCPInventory.discover(home: fake.home, project: nil, environment: ["CODEX_HOME": codexHome])
        #expect(inventory.entries.map(\.name) == ["x"])
    }

    @Test func statusesAndRedactedRows() throws {
        let fake = try populated()
        let inventory = MCPInventory.discover(home: fake.home, project: fake.project, environment: [:])
        let configuration = MCPConfiguration(
            servers: [MCPServerDefinition(name: "github", command: "npx"), MCPServerDefinition(name: "team", command: "uvx")],
            direct: ["hosted", "stripe"],
            blocked: ["filesystem"])
        let rows = MCPInventoryRow.rows(inventory, configuration: configuration)
        func row(_ name: String) throws -> MCPInventoryRow { try #require(rows.first { $0.entry.name == name }) }

        #expect(try row("github").status == .governed)
        #expect(try row("team").status == .bypass)
        #expect(try row("hosted").status == .direct)
        #expect(try row("stripe").status == .disabled)
        #expect(try row("filesystem").status == .blocked)
        #expect(try row("oc").status == .disabled)
        #expect(try row("wax").status == .unreviewed)

        let context7 = try row("context7")
        #expect(context7.display == "npx -y @upstash/context7-mcp --api-key <redacted>")
        #expect(context7.plaintextCredentials == ["--api-key"])
        #expect(try row("wax").plaintextCredentials == ["WAX_TOKEN"])
        #expect(try row("wax").environmentNames == ["WAX_TOKEN"])
        #expect(try row("remote").display == "https://mcp.example.com/…")
        #expect(try row("remote").plaintextCredentials == ["URL"])
        for row in rows {
            #expect(row.display.contains("ctx7sk") == false)
            #expect(row.display.contains("secretvalue") == false)
        }

        let dangling = MCPHostEntry(
            host: .cursor, scope: .user, configPath: "/x", name: "gone",
            transport: .stdio(command: "rv", args: ["mcp", "serve", "--server=gone"]))
        #expect(MCPInventoryRow.status(dangling, configuration: configuration) == .dangling)
        #expect(MCPEntryStatus.dangling.isAcceptable == false)
        #expect(MCPEntryStatus.governed.isAcceptable)
    }
}
