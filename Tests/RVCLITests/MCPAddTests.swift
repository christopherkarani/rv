import Foundation
import RVDomain
import RVIsolation
import RVMCP
import Synchronization
import Testing
@testable import RVCLI

private typealias JSONValue = RVMCP.JSONValue

/// `rv mcp add` and `rv mcp remove` end to end, in a temporary HOME: the
/// host configs, mcp.json, secrets.json, backups and the Keychain are all
/// fixtures. Presence and the terminal are injected; no server is started.
@Suite("rv mcp add")
struct MCPAddTests {
    static let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    static let waxToken = "wax_live_abcdefghijklmnopqrstuvwxyz0123"
    static let cursor = """
        {
          "mcpServers": {
            "github": {
              "command": "npx",
              "args": [
                "-y",
                "@modelcontextprotocol/server-github"
              ],
              "env": {
                "GITHUB_PERSONAL_ACCESS_TOKEN": "\(token)"
              }
            },
            "wax": {
              "url": "https://wax.example.com/mcp",
              "headers": {
                "Authorization": "Bearer \(waxToken)"
              }
            },
            "linear": {
              "url": "https://user:hunter2@linear.example.com/mcp"
            }
          }
        }

        """

    /// Counts owner confirmations and keeps every reason shown for one.
    final class Presence: Sendable {
        let reasons = Mutex<[String]>([])
        let answer: PresenceOutcome
        init(_ answer: PresenceOutcome = .confirmed(method: "test")) { self.answer = answer }
        var presence: UserPresence {
            UserPresence { reason, _ in
                self.reasons.withLock { $0.append(reason) }
                return self.answer
            }
        }
        var count: Int { reasons.withLock { $0.count } }
    }

    final class Shown: Sendable {
        let text = Mutex("")
        var show: @Sendable (String) -> Void { { piece in self.text.withLock { $0 += piece } } }
        var value: String { text.withLock { $0 } }
    }

    static func rv(_ fixture: MCPCommandTests.Fixture) throws -> String {
        let rv = fixture.home.appendingPathComponent("bin/rv")
        try FileManager.default.createDirectory(at: rv.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: rv.path, contents: Data())
        return rv.path
    }

    static func request(
        _ fixture: MCPCommandTests.Fixture, hosts: Set<MCPHost>? = [.cursor], typed: String? = "cursor",
        preview: Bool = false
    ) throws -> MCPAdoptRun.Request {
        let rv = try rv(fixture)
        return MCPAdoptRun.Request(
            hosts: hosts, typed: typed, project: nil, preview: preview, rvPath: rv, rvExecutable: rv)
    }

    static func mcpJSON(_ fixture: MCPCommandTests.Fixture) -> URL {
        fixture.config.appendingPathComponent("mcp.json")
    }

    @Test func previewShowsWhatRvWouldDoAndChangesNothing() async throws {
        let fixture = MCPCommandTests.Fixture()
        try fixture.write(".cursor/mcp.json", Self.cursor)
        let presence = Presence()
        let text = try await MCPAdoptRun.add(
            Self.request(fixture, preview: true), environment: fixture.environment(presence: presence.presence),
            hasTerminal: { false }, show: { _ in }
        ).get()
        print("=== rv mcp add cursor --preview\n" + text)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == "◆ rv found 3 MCP servers in Cursor, 3 not governed")
        #expect(lines.contains("  ◐ github  npx -y @modelcontextprotocol/server-github · local · no sandbox yet")
            || lines.contains { $0.hasPrefix("  ◐ github  npx -y @modelcontextprotocol/server-github · sealed") })
        #expect(lines.contains("  ◐ wax     https://wax.example.com/… · remote"))
        #expect(lines.contains {
            $0.hasPrefix("  ✕ linear  url must be given without credentials")
        })
        #expect(lines.contains("  2 keys move to \(SecretKeychain.storeName): GITHUB_PERSONAL_ACCESS_TOKEN, WAX_AUTHORIZATION"))
        #expect(lines.contains("  ~/.cursor/mcp.json"))
        #expect(lines.contains(#"  + "wax": {"command":"\#(try Self.rv(fixture))","args":["mcp","serve","--server","wax"]}"#))
        #expect(lines.suffix(2) == ["  nothing changed yet", "→ rv mcp add cursor"])
        #expect(text.contains(Self.token) == false && text.contains(Self.waxToken) == false && text.contains("hunter2") == false)
        #expect(fixture.text(".cursor/mcp.json") == Self.cursor)
        #expect(FileManager.default.fileExists(atPath: Self.mcpJSON(fixture).path) == false)
        #expect(presence.count == 0)
    }

    @Test func anAgentWithoutATerminalIsRefusedBeforeAnythingIsRead() async throws {
        let fixture = MCPCommandTests.Fixture()
        try fixture.write(".cursor/mcp.json", Self.cursor)
        let presence = Presence()
        let result = await MCPAdoptRun.add(
            try Self.request(fixture), environment: fixture.environment(presence: presence.presence),
            hasTerminal: { false }, show: { _ in })
        guard case .failure(let failure) = result else {
            Issue.record("add ran without a terminal")
            return
        }
        print("=== rv mcp add cursor (no terminal)\n" + failure.message)
        #expect(failure.message == """
            ✕ needs you at your own terminal, and this process has no terminal; nothing changed
            → rv mcp add cursor
            """)
        #expect(presence.count == 0)
        #expect(fixture.text(".cursor/mcp.json") == Self.cursor)
        #expect(FileManager.default.fileExists(atPath: Self.mcpJSON(fixture).path) == false)
    }

    @Test func oneConfirmationImportsRoutesAndBacksUp() async throws {
        let fixture = MCPCommandTests.Fixture()
        try fixture.write(".cursor/mcp.json", Self.cursor)
        let presence = Presence()
        let shown = Shown()
        let text = try await MCPAdoptRun.add(
            Self.request(fixture), environment: fixture.environment(presence: presence.presence),
            hasTerminal: { true }, show: shown.show
        ).get()
        print("=== rv mcp add cursor\n" + shown.value + text)
        #expect(presence.count == 1)
        // The one confirmation covers the import and every host rewrite.
        let first = presence.reasons.withLock { $0.first }
        let reason = try #require(first)
        #expect(reason.contains(#"  + "github": {"command":"#))
        #expect(text.hasPrefix("✓ 2 servers through rv. Restart Cursor once.\n  undo: rv mcp remove cursor\n"))
        #expect(text.contains("  1 file backed up first, in ~/.config/rv/backups"))
        let configuration = try MCPRun.configuration(fixture.environment()).get()
        #expect(configuration.servers.map(\.name).sorted() == ["github", "wax"])
        let host = fixture.text(".cursor/mcp.json")
        #expect(host.contains(#""args": ["#) && host.contains(#""serve""#))
        #expect(host.contains(Self.token) == false)
        #expect(host.contains("hunter2"))
        let stored = fixture.keychain.items.withLock { $0 }
        #expect(stored["\(SecretKeychain.service)/GITHUB_PERSONAL_ACCESS_TOKEN"] == Data(Self.token.utf8))
        let backups = try FileManager.default.contentsOfDirectory(atPath: fixture.config.appendingPathComponent("backups").path)
        #expect(backups.count == 1)
        let everything = shown.value + text + presence.reasons.withLock { $0.joined() }
        #expect(everything.contains(Self.token) == false && everything.contains(Self.waxToken) == false)
    }

    @Test func aRefusedConfirmationChangesNothing() async throws {
        let fixture = MCPCommandTests.Fixture()
        try fixture.write(".cursor/mcp.json", Self.cursor)
        let presence = Presence(.refused("Touch ID was cancelled"))
        let result = await MCPAdoptRun.add(
            try Self.request(fixture), environment: fixture.environment(presence: presence.presence),
            hasTerminal: { true }, show: { _ in })
        guard case .failure(let failure) = result else {
            Issue.record("add went ahead without a confirmation")
            return
        }
        #expect(failure.message.hasPrefix("✕ not imported: Touch ID was cancelled"))
        #expect(fixture.text(".cursor/mcp.json") == Self.cursor)
        #expect(FileManager.default.fileExists(atPath: Self.mcpJSON(fixture).path) == false)
        let stored = fixture.keychain.items.withLock { $0 }
        #expect(stored.isEmpty)
    }

    @Test func removePutsTheHostBackAsItWas() async throws {
        let fixture = MCPCommandTests.Fixture()
        try fixture.write(".cursor/mcp.json", Self.cursor)
        let presence = Presence()
        _ = try await MCPAdoptRun.add(
            Self.request(fixture), environment: fixture.environment(presence: presence.presence),
            hasTerminal: { true }, show: { _ in }
        ).get()
        let preview = try await MCPAdoptRun.remove(
            hosts: [.cursor], typed: "cursor", preview: true, environment: fixture.environment(presence: presence.presence),
            hasTerminal: { false }, show: { _ in }
        ).get()
        print("=== rv mcp remove cursor --preview\n" + preview)
        #expect(preview.hasPrefix("◆ rv puts back 2 servers in Cursor\n  ~/.cursor/mcp.json\n"))
        #expect(preview.contains(Self.token) == false)
        let refused = await MCPAdoptRun.remove(
            hosts: [.cursor], typed: "cursor", preview: false, environment: fixture.environment(presence: presence.presence),
            hasTerminal: { false }, show: { _ in })
        #expect((try? refused.get()) == nil)
        let text = try await MCPAdoptRun.remove(
            hosts: [.cursor], typed: "cursor", preview: false, environment: fixture.environment(presence: presence.presence),
            hasTerminal: { true }, show: { _ in }
        ).get()
        print("=== rv mcp remove cursor\n" + text)
        #expect(text.hasPrefix("✓ Cursor is back as it was.\n"))
        #expect(presence.count == 2)
        let original = try JSONValue.parse(Self.cursor)
        let restored = try JSONValue.parse(fixture.text(".cursor/mcp.json"))
        #expect(restored == original)
        let again = try await MCPAdoptRun.remove(
            hosts: [.cursor], typed: "cursor", preview: false, environment: fixture.environment(presence: presence.presence),
            hasTerminal: { true }, show: { _ in }
        ).get()
        #expect(again == "◆ rv has nothing to put back in Cursor\n")
    }

    @Test func everyHostAtOnce() async throws {
        let fixture = MCPCommandTests.Fixture()
        try fixture.write(".cursor/mcp.json", Self.cursor)
        try fixture.write(".claude.json", #"{"mcpServers": {"notes": {"command": "uvx", "args": ["notes-mcp"]}}}"#)
        try fixture.write(".codex/config.toml", "[mcp_servers.todo]\ncommand = \"todo-mcp\"\n")
        let text = try await MCPAdoptRun.add(
            Self.request(fixture, hosts: nil, typed: nil, preview: true), environment: fixture.environment(),
            hasTerminal: { false }, show: { _ in }
        ).get()
        print("=== rv mcp add --preview\n" + text)
        #expect(text.hasPrefix("◆ rv found 5 MCP servers in 3 hosts, 5 not governed\n  Claude Code\n"))
        #expect(text.contains("  Codex keeps servers in TOML, which rv does not rewrite; after this, run:"))
        #expect(text.hasSuffix("  nothing changed yet\n→ rv mcp add\n"))
    }

    @Test func nothingToAddSaysSo() async throws {
        let fixture = MCPCommandTests.Fixture()
        let text = try await MCPAdoptRun.add(
            Self.request(fixture, preview: true), environment: fixture.environment(),
            hasTerminal: { true }, show: { _ in }
        ).get()
        #expect(text == "◆ rv found no MCP servers in Cursor\n  nothing to add\n")
    }

    @Test func setupNamesTheServersOutsideRv() throws {
        let fixture = MCPCommandTests.Fixture()
        let rv = try Self.rv(fixture)
        #expect(MCPAdoptRun.setupHint(environment: fixture.environment(), project: nil, rvExecutable: rv) == nil)
        try fixture.write(".cursor/mcp.json", Self.cursor)
        let hint = MCPAdoptRun.setupHint(environment: fixture.environment(), project: nil, rvExecutable: rv)
        print("=== rv setup (MCP hint)\n" + (hint ?? ""))
        #expect(hint == "◆ rv found 3 MCP servers in Cursor, 3 not governed\n→ rv mcp add")
    }

    @Test func hostWordsParse() throws {
        #expect(try MCPAdoptRun.host("claude") == [.claudeCode])
        #expect(try MCPAdoptRun.host(nil) == nil)
        #expect(throws: (any Error).self) { try MCPAdoptRun.host("cursr") }
    }
}
