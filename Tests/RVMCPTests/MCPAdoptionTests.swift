import Foundation
import RVDomain
import RVIsolation
import Testing
@testable import RVMCP

private typealias JSONValue = RVMCP.JSONValue

/// `rv mcp add`'s discovery and plan, as pure functions over file
/// contents. Files are an in-memory map under a home that does not exist;
/// nothing on disk is read but the stand-in rv binary, and no server runs.
@Suite("MCP adoption")
struct MCPAdoptionTests {
    static let home = URL(fileURLWithPath: "/rv-adoption-home-that-does-not-exist", isDirectory: true)
    static let githubToken = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    static let waxToken = "wax_live_abcdefghijklmnopqrstuvwxyz0123"

    static func path(_ location: MCPHostConfigLocation) -> String {
        location.path(home: home.path, codexHome: nil, project: nil) ?? ""
    }

    /// A stand-in rv executable: `governed` compares real files.
    final class RVBinary {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-adopt-\(UUID().uuidString)")
        var path: String { directory.appendingPathComponent("rv").path }
        init() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: path, contents: Data())
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    static func files(rv: String) -> [String: String] {
        [
            path(.claudeCodeUser): """
                {"numStartups": 3, "mcpServers": {
                  "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
                             "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "\(githubToken)"}},
                  "docs": {"command": "\(rv)", "args": ["mcp", "serve", "--server", "docs"]}
                }}
                """,
            path(.cursorUser): """
                {
                  "mcpServers": {
                    "github": {
                      "command": "npx",
                      "args": [
                        "-y",
                        "@modelcontextprotocol/server-github"
                      ],
                      "env": {
                        "GITHUB_PERSONAL_ACCESS_TOKEN": "\(githubToken)"
                      }
                    },
                    "wax": {
                      "url": "https://wax.example.com/mcp",
                      "headers": {
                        "Authorization": "Bearer \(waxToken)"
                      }
                    },
                    "old": {
                      "command": "old-mcp",
                      "disabled": true
                    }
                  }
                }

                """,
            path(.codexUser): """
                [mcp_servers.notes]
                command = "uvx"
                args = ["notes-mcp"]
                """,
        ]
    }

    static func reader(_ files: [String: String]) -> (URL) -> MCPInventory.HostFile {
        { url in files[url.path].map { .data(Data($0.utf8)) } ?? .missing }
    }

    static func inventory(_ files: [String: String]) -> MCPInventory {
        MCPInventory.discover(
            home: home, project: nil, environment: [:], managedDirectory: home.path + "/managed",
            read: reader(files), list: { _ in [] })
    }

    static func survey(
        _ files: [String: String], rv: String, configuration: MCPConfiguration = MCPConfiguration(),
        hosts: Set<MCPHost>? = nil
    ) -> MCPAdoptionSurvey {
        MCPAdoption.survey(
            entries: inventory(files).entries, configuration: configuration, secrets: SecretsConfiguration(),
            rvExecutable: rv, hosts: hosts)
    }

    static func verdict(_ survey: MCPAdoptionSurvey, _ host: MCPHost, _ name: String) -> MCPAdoptionVerdict? {
        survey.rows.first { $0.host == host && $0.name == name }?.verdict
    }

    @Test func findsEveryHostsServersAndCountsTheUngoverned() {
        let rv = RVBinary()
        defer { rv.remove() }
        // `docs` already runs through rv: the host launches this rv for a server mcp.json has.
        let configuration = MCPConfiguration(servers: [MCPServerDefinition(name: "docs", command: "docs-mcp")])
        let survey = Self.survey(Self.files(rv: rv.path), rv: rv.path, configuration: configuration)
        #expect(survey.hosts == [.claudeCode, .cursor, .codex])
        #expect(survey.found == 6)
        #expect(survey.notGoverned == 5)
        #expect(survey.adopting == 4)
        #expect(Self.verdict(survey, .claudeCode, "docs") == .governed)
        #expect(Self.verdict(survey, .claudeCode, "github") == .adopt(.local(sandbox: survey.imports.servers.first?.sandbox)))
        #expect(Self.verdict(survey, .cursor, "wax") == .adopt(.remote))
        #expect(Self.verdict(survey, .cursor, "old") == .leave("turned off in Cursor; turn it on, then rv mcp add"))
        // One reviewed definition per name, however many hosts share it.
        #expect(survey.imports.servers.map(\.name).sorted() == ["github", "notes", "wax"])
        #expect(survey.routes == [.claudeCode: ["github"], .cursor: ["github", "wax"], .codex: ["notes"]])
        #expect(survey.keys.sorted() == ["GITHUB_PERSONAL_ACCESS_TOKEN", "WAX_AUTHORIZATION"])
        #expect(survey.rows.first { $0.name == "wax" }?.keys == ["WAX_AUTHORIZATION"])
    }

    @Test func oneHostAtATime() {
        let rv = RVBinary()
        defer { rv.remove() }
        let survey = Self.survey(Self.files(rv: rv.path), rv: rv.path, hosts: [.cursor])
        #expect(survey.hosts == [.cursor])
        #expect(survey.found == 3)
        #expect(survey.notGoverned == 3)
        #expect(survey.routes == [.cursor: ["github", "wax"]])
    }

    @Test func noSecretValueReachesAnythingShown() throws {
        let rv = RVBinary()
        defer { rv.remove() }
        let files = Self.files(rv: rv.path)
        let survey = Self.survey(files, rv: rv.path)
        let preview = try MCPAdoption.routePreview(
            survey, files: MCPHostFile.all(home: Self.home, project: nil, environment: [:]),
            configuration: MCPConfiguration(), rvPath: "/usr/local/bin/rv", read: Self.reader(files)
        ).get()
        let shown = (survey.rows.map(\.shown) + survey.rows.map { "\($0.verdict)" } + survey.keys
            + preview.changes.flatMap { [$0.before, $0.after] } + preview.manualSteps).joined(separator: "\n")
        #expect(shown.contains(Self.githubToken) == false)
        #expect(shown.contains(Self.waxToken) == false)
        #expect(shown.contains("ghp_") == false && shown.contains("wax_live") == false)
        #expect(shown.contains("GITHUB_PERSONAL_ACCESS_TOKEN"))
    }

    @Test func previewShowsEachRewriteBeforeAndAfter() throws {
        let rv = RVBinary()
        defer { rv.remove() }
        let files = Self.files(rv: rv.path)
        let survey = Self.survey(files, rv: rv.path)
        let preview = try MCPAdoption.routePreview(
            survey, files: MCPHostFile.all(home: Self.home, project: nil, environment: [:]),
            configuration: MCPConfiguration(), rvPath: "/usr/local/bin/rv", read: Self.reader(files)
        ).get()
        #expect(preview.paths == [Self.path(.claudeCodeUser), Self.path(.cursorUser)])
        #expect(preview.changes.map(\.name) == ["github", "github", "wax"])
        let wax = try #require(preview.changes.first { $0.name == "wax" })
        #expect(wax.before == #""wax": {"url":"https://wax.example.com/…","headers":{"Authorization":"<redacted>"}}"#)
        #expect(wax.after == #""wax": {"command":"/usr/local/bin/rv","args":["mcp","serve","--server","wax"]}"#)
        let github = try #require(preview.changes.first { $0.host == .cursor && $0.name == "github" })
        #expect(github.before.contains(#""env":{"GITHUB_PERSONAL_ACCESS_TOKEN":"<redacted>"}"#))
        // Codex keeps TOML: one command, never a rewrite.
        #expect(preview.manualSteps == [
            "codex mcp remove 'notes' && codex mcp add 'notes' -- '/usr/local/bin/rv' mcp serve --server 'notes'",
        ])
        // ~/.claude.json is compact on disk, so rv writes it back in its own layout.
        #expect(preview.relaid == [Self.path(.claudeCodeUser)])
    }

    @Test func sameNameDifferentServersStayOutEverywhere() {
        let rv = RVBinary()
        defer { rv.remove() }
        var files = Self.files(rv: rv.path)
        files[Self.path(.geminiUser)] = #"{"mcpServers": {"github": {"command": "npx", "args": ["-y", "someone-elses-github"]}}}"#
        let survey = Self.survey(files, rv: rv.path)
        let reason = "Claude Code and Cursor and Gemini run different servers named github; rename one, then rv mcp add"
        #expect(Self.verdict(survey, .claudeCode, "github") == .leave(reason))
        #expect(Self.verdict(survey, .cursor, "github") == .leave(reason))
        #expect(Self.verdict(survey, .gemini, "github") == .leave(reason))
        #expect(survey.imports.servers.map(\.name).sorted() == ["notes", "wax"])
        #expect(survey.routes[.claudeCode] == nil)
    }

    @Test func aHostWithTwoDifferentEntriesOfOneNameStaysOut() {
        let rv = RVBinary()
        defer { rv.remove() }
        let project = URL(fileURLWithPath: "/rv-adoption-project", isDirectory: true)
        let files = [
            Self.path(.cursorUser): #"{"mcpServers": {"db": {"command": "db-mcp"}}}"#,
            project.path + "/.cursor/mcp.json": #"{"mcpServers": {"db": {"command": "db-mcp", "args": ["--prod"]}}}"#,
        ]
        let inventory = MCPInventory.discover(
            home: Self.home, project: project, environment: [:], managedDirectory: Self.home.path + "/managed",
            read: Self.reader(files), list: { _ in [] })
        let survey = MCPAdoption.survey(
            entries: inventory.entries, configuration: MCPConfiguration(), secrets: SecretsConfiguration(),
            rvExecutable: rv.path)
        #expect(survey.found == 2)
        #expect(survey.adopting == 0)
        #expect(survey.rows.allSatisfy {
            $0.verdict == .leave("Cursor has two different servers named db; rename one, then rv mcp add")
        })
    }

    @Test func whatRvCannotTakeSaysWhyInOneLine() throws {
        let rv = RVBinary()
        defer { rv.remove() }
        var configuration = MCPConfiguration()
        configuration.blocked = ["evil"]
        configuration.direct = ["local-ok"]
        let files = [
            Self.path(.cursorUser): """
                {"mcpServers": {
                  "evil": {"command": "evil"},
                  "local-ok": {"command": "ok"},
                  "bad name!": {"command": "x"},
                  "leaky": {"url": "https://user:hunter2@leaky.example.com/mcp"},
                  "gone": {"command": "\(rv.path)", "args": ["mcp", "serve", "--server", "gone"]}
                }}
                """,
        ]
        let survey = Self.survey(files, rv: rv.path, configuration: configuration)
        let reasons = Dictionary(uniqueKeysWithValues: survey.rows.compactMap { row -> (String, String)? in
            guard case .leave(let reason) = row.verdict else { return nil }
            return (row.name, reason)
        })
        #expect(reasons["evil"] == "mcp.json blocks it; remove it from Cursor")
        #expect(reasons["local-ok"] == "mcp.json lets it run outside rv (\"direct\")")
        #expect(reasons["bad name!"] == "name is not a valid rv server name")
        #expect(reasons["leaky"] == "url must be given without credentials (send them as headers with ${secret:NAME})")
        #expect(reasons["gone"] == "points at rv, but mcp.json has no gone")
        #expect(reasons.values.allSatisfy { $0.contains("\n") == false })
        #expect(survey.adopting == 0)
        #expect(survey.rows.map(\.shown).joined().contains("hunter2") == false)
    }

    @Test func pluginAndManagedServersAreReadOnly() {
        let entries = [
            MCPHostEntry(
                host: .claudeCode, scope: .plugin("tools@market"), configPath: "/p/.mcp.json", name: "tools",
                transport: .stdio(command: "tools", args: [])),
            MCPHostEntry(
                host: .claudeCode, scope: .managed, configPath: "/etc/claude-code/managed-mcp.json", name: "corp",
                transport: .stdio(command: "corp", args: [])),
        ]
        let survey = MCPAdoption.survey(
            entries: entries, configuration: MCPConfiguration(), secrets: SecretsConfiguration(), rvExecutable: "")
        #expect(survey.rows.map(\.verdict) == [
            .leave("plugin tools@market brings it; rv can't rewrite a plugin"),
            .leave("your organization's managed config sets it; rv can't rewrite that file"),
        ])
        #expect(survey.imports.servers.isEmpty)
    }

    @Test func aServerRvAlreadyReviewedIsOnlyRouted() throws {
        let rv = RVBinary()
        defer { rv.remove() }
        var configuration = MCPConfiguration()
        let url = try #require(URL(string: "https://wax.example.com/mcp"))
        configuration.servers = [MCPServerDefinition(name: "wax", remote: MCPRemoteServer(url: url, transport: .http))]
        let survey = Self.survey(Self.files(rv: rv.path), rv: rv.path, configuration: configuration, hosts: [.cursor])
        #expect(Self.verdict(survey, .cursor, "wax") == .adopt(.reviewed))
        #expect(survey.imports.servers.map(\.name) == ["github"])
        #expect(survey.routes[.cursor] == ["github", "wax"])
    }

    @Test func undoPreviewListsOnlyEntriesStillAsRvWroteThem() {
        let written = JSONValue.object(["command": .string("/usr/local/bin/rv"), "args": .array(
            ["mcp", "serve", "--server", "github"].map(JSONValue.string))])
        let original = JSONValue.object([
            "command": .string("npx"), "env": .object(["GITHUB_TOKEN": .string(Self.githubToken)]),
        ])
        let records = [
            MCPSetupRecord(
                host: "cursor", configPath: "/c/mcp.json", keyPath: ["mcpServers"], name: "github",
                original: original, written: written),
            MCPSetupRecord(
                host: "cursor", configPath: "/c/mcp.json", keyPath: ["mcpServers"], name: "edited",
                original: original, written: written),
            MCPSetupRecord(
                host: "gemini", configPath: "/g/settings.json", keyPath: ["mcpServers"], name: "github",
                original: original, written: written),
        ]
        let files = [
            "/c/mcp.json": #"{"mcpServers": {"github": {"command": "/usr/local/bin/rv", "args": ["mcp", "serve", "--server", "github"]}, "edited": {"command": "mine"}}}"#,
        ]
        let changes = MCPAdoption.undoPreview(records: records, host: .cursor, read: Self.reader(files))
        #expect(changes.map(\.name) == ["github"])
        #expect(changes.first?.after == #""github": {"command":"npx","env":{"GITHUB_TOKEN":"<redacted>"}}"#)
        #expect(MCPAdoption.undoPreview(records: records, host: nil, read: Self.reader(files)).count == 1)
    }

    @Test func maskingKeepsNamesAndHidesValues() {
        let entry = JSONValue.object([
            "command": .array(["/bin/srv", "--token", Self.githubToken].map(JSONValue.string)),
            "environment": .object(["LOG_LEVEL": .string("debug"), "API_KEY": .string("plain-but-hidden")]),
            "http_headers": .object(["X-Api-Key": .string("abc")]),
            "args": .array(["--api-key=\(Self.githubToken)", "--port", "8080"].map(JSONValue.string)),
            "secret": .string("hunter2"),
            "note": .string("\u{1B}[2Jgone"),
        ])
        let shown = MCPAdoption.shownEntry("srv", entry)
        #expect(shown.contains(Self.githubToken) == false)
        #expect(shown.contains("plain-but-hidden") == false && shown.contains("debug") == false)
        #expect(shown.contains("hunter2") == false && shown.contains("abc") == false)
        #expect(shown.contains("LOG_LEVEL") && shown.contains("X-Api-Key") && shown.contains("8080"))
        #expect(shown.unicodeScalars.contains { $0.value == 0x1B } == false)
    }

    @Test(arguments: [
        ("claude", MCPHost.claudeCode), ("claude-code", .claudeCode), ("Cursor", .cursor), ("codex", .codex),
        ("vscode", .vscode),
    ])
    func hostWords(_ word: String, _ host: MCPHost) {
        #expect(MCPHost(word: word) == host)
    }

    @Test func unknownHostWordIsNil() {
        #expect(MCPHost(word: "cursr") == nil)
        #expect(MCPHost.allCases.map(\.displayName).contains("Claude Code"))
    }
}
