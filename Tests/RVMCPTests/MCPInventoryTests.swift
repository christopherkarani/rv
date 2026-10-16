#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
        let nested = MCPRedaction.url("https://mcp.example/mcp?next=https://user:supersecretpassword@evil.example/x")
        #expect(nested.leaked)
        #expect(nested.display.contains("supersecretpassword") == false)
        let nestedPath = MCPRedaction.url("https://mcp.example/mcp?next=https://evil.example/ghp_1234567890abcdefghij")
        #expect(nestedPath.leaked)
        #expect(nestedPath.display.contains("ghp_") == false)
        #expect(MCPRedaction.url("https://mcp.example/mcp?next=https://collector.example/v1").leaked == false)
        #expect(MCPRedaction.url("https://mcp.example/.ghp_1234567890abcdefghij").leaked)
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
        var rv: URL { home.appendingPathComponent("bin/rv") }

        func makeRV() throws {
            try FileManager.default.createDirectory(at: rv.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: rv.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        func write(_ relative: String, under base: URL? = nil, _ text: String) throws {
            let url = (base ?? home).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func populated() throws -> FakeHome {
        let fake = FakeHome()
        try fake.makeRV()
        let projectPath = fake.project.standardizedFileURL.path
        try fake.write(".claude.json", """
            {"numStartups": 3, "mcpServers": {"wax": {"type": "stdio", "command": "wax-mcp", "args": [], "env": {"WAX_TOKEN": "secretvalue"}}},
             "projects": {"\(projectPath)": {"mcpServers": {"local-one": {"command": "node", "args": ["x.js"]}}}}}
            """)
        try fake.write(".cursor/mcp.json", #"{"mcpServers": {"github": {"command": "\#(fake.rv.path)", "args": ["mcp", "serve", "--server", "github"]}}}"#)
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
        let rows = MCPInventoryRow.rows(inventory, configuration: configuration, rvExecutable: fake.rv.path)
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
            transport: .stdio(command: fake.rv.path, args: ["mcp", "serve", "--server=gone"]))
        #expect(MCPInventoryRow.status(dangling, configuration: configuration, rvExecutable: fake.rv.path) == .dangling)
        #expect(MCPEntryStatus.dangling.isAcceptable == false)
        #expect(MCPEntryStatus.governed.isAcceptable)

        let relative = MCPHostEntry(
            host: .cursor, scope: .user, configPath: "/x", name: "github",
            transport: .stdio(command: "rv", args: ["mcp", "serve", "--server", "github"]))
        #expect(MCPInventoryRow.status(relative, configuration: configuration, rvExecutable: fake.rv.path) == .bypass)
        let dotted = MCPHostEntry(
            host: .cursor, scope: .user, configPath: "/x", name: "github",
            transport: .stdio(command: "./rv", args: ["mcp", "serve", "--server", "github"]))
        #expect(MCPInventoryRow.status(dotted, configuration: configuration, rvExecutable: fake.rv.path) == .bypass)

        let other = fake.home.appendingPathComponent("bin/not-rv")
        #expect(FileManager.default.createFile(atPath: other.path, contents: Data()))
        let imposter = MCPHostEntry(
            host: .cursor, scope: .user, configPath: "/x", name: "github",
            transport: .stdio(command: other.path, args: ["mcp", "serve", "--server", "github"]))
        #expect(MCPInventoryRow.status(imposter, configuration: configuration, rvExecutable: fake.rv.path) == .bypass)

        let extra = MCPHostEntry(
            host: .cursor, scope: .user, configPath: "/x", name: "github",
            transport: .stdio(command: fake.rv.path, args: ["mcp", "serve", "--server", "github", "--server", "other"]))
        #expect(MCPInventoryRow.status(extra, configuration: configuration, rvExecutable: fake.rv.path) == .bypass)
        let equals = MCPHostEntry(
            host: .cursor, scope: .user, configPath: "/x", name: "github",
            transport: .stdio(command: fake.rv.path, args: ["mcp", "serve", "--server=github"]))
        #expect(MCPInventoryRow.status(equals, configuration: configuration, rvExecutable: fake.rv.path) == .governed)
    }

    @Test func unreadableAndOversizedHostFilesFailTheInventory() throws {
        let fake = FakeHome()
        try fake.write(".cursor/mcp.json", #"{"mcpServers": {"x": {"command": "x"}}}"#)
        let denied = fake.home.appendingPathComponent(".cursor/mcp.json")
        #expect(chmod(denied.path, 0o000) == 0)
        defer { _ = chmod(denied.path, 0o600) }
        let deniedInventory = MCPInventory.discover(home: fake.home, project: nil, environment: [:])
        #expect(deniedInventory.entries.isEmpty)
        #expect(deniedInventory.problems.contains { $0.path == denied.path && $0.message == "permission denied" })

        let huge = fake.home.appendingPathComponent(".claude.json")
        let fd = open(huge.path, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0o600)
        #expect(fd >= 0)
        #expect(ftruncate(fd, off_t(MCPInventory.maximumFileBytes + 1)) == 0)
        #expect(close(fd) == 0)
        let hugeInventory = MCPInventory.discover(home: fake.home, project: nil, environment: [:])
        #expect(hugeInventory.problems.contains { $0.path == huge.path && $0.message.contains("larger than") })
        #expect(hugeInventory.entries.contains { $0.name == "x" } == false)

        try FileManager.default.createDirectory(at: fake.home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fake.home.appendingPathComponent(".codex/config.toml"), withIntermediateDirectories: true)
        let directoryInventory = MCPInventory.discover(home: fake.home, project: nil, environment: [:])
        let directory = fake.home.appendingPathComponent(".codex/config.toml").path
        #expect(directoryInventory.problems.contains { $0.path == directory && $0.message == "not a regular file" })

        let missing = MCPInventory.discover(home: fake.root.appendingPathComponent("empty-home"), project: nil, environment: [:])
        #expect(missing.problems.isEmpty)
        #expect(missing.entries.isEmpty)
    }

    @Test func claudeProjectKeysMatchCanonicalPaths() throws {
        let fake = FakeHome()
        try FileManager.default.createDirectory(at: fake.project, withIntermediateDirectories: true)
        let link = fake.root.appendingPathComponent("linked-project")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fake.project)
        let real = MCPInventory.canonicalProjectPath(fake.project.path)
        let viaLink = link.path
        let viaDots = fake.project.appendingPathComponent("../\(fake.project.lastPathComponent)").path
        try fake.write(".claude.json", """
            {"projects": {
              "\(viaLink)/": {"mcpServers": {"from-link": {"command": "node", "args": ["a.js"]}}},
              "\(viaDots)": {"mcpServers": {"from-dots": {"command": "node", "args": ["b.js"]}}},
              "/not/the/project": {"mcpServers": {"hidden": {"command": "node", "args": ["c.js"]}}}
            }}
            """)
        let inventory = MCPInventory.discover(home: fake.home, project: fake.project, environment: [:])
        let names = Set(inventory.entries.map(\.name))
        #expect(names.contains("from-link"))
        #expect(names.contains("from-dots"))
        #expect(names.contains("hidden") == false)
        #expect(MCPInventory.canonicalProjectPath(viaLink) == real)
        #expect(MCPInventory.canonicalProjectPath(viaDots) == real)
    }
}
