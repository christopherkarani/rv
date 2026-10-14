import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RVHistory
import RVIsolation
import RVMCP
import RVPolicy
import Synchronization
import Testing
@testable import RVCLI

@Suite("rv mcp commands")
struct MCPCommandTests {
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-cli-\(UUID().uuidString)")
        let keychain = FakeKeychain()
        var home: URL { root.appendingPathComponent("home") }
        var config: URL { home.appendingPathComponent(".config/rv") }

        func environment(
            keychain writer: SecretKeychainWriter? = nil, presence: UserPresence = MCPCommandTests.present
        ) -> MCPEnvironment {
            MCPEnvironment(
                configDirectory: config, home: home, processEnvironment: [:], keychain: writer ?? keychain.writer,
                approvalKeys: .file(configDirectory: config), presence: presence, oauthTokens: .file(configDirectory: config))
        }

        func approvalEvents() -> [AuditEvent] {
            AuditLedger(configDirectory: config).events(AuditFilter(kinds: [AuditEventKind.mcpApproval.rawValue]))
        }

        @discardableResult
        func write(_ relative: String, _ text: String) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }

        func text(_ relative: String) -> String {
            (try? String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8)) ?? ""
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static let cursorConfig = """
        {"mcpServers": {
          "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
                     "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789"}},
          "seq": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-sequential-thinking"]}
        }}
        """

    private func report(_ fixture: Fixture, rvExecutable: String = "") throws -> MCPRun.Report {
        let environment = fixture.environment()
        let configuration = try MCPRun.configuration(environment).get()
        return MCPRun.report(environment, project: nil, configuration: configuration, rvExecutable: rvExecutable)
    }

    @Test func importThenSetupTakesCheckFromFailingToPassing() async throws {
        let fixture = Fixture()
        try fixture.write(".cursor/mcp.json", Self.cursorConfig)
        #expect(try report(fixture).passes == false)
        #expect(MCPRun.checkText(try report(fixture), home: fixture.home).contains("plaintext"))

        let imported = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false, environment: fixture.environment()
        ).get()
        #expect(imported.contains("import github: npx (credentials → rv secrets GITHUB_PERSONAL_ACCESS_TOKEN)"))
        #expect(imported.contains("ghp_") == false)
        #expect(fixture.keychain.items.withLock { $0["\(SecretKeychain.service)/GITHUB_PERSONAL_ACCESS_TOKEN"] }
            == Data("ghp_abcdefghijklmnopqrstuvwxyz0123456789".utf8))
        #expect(fixture.text(".config/rv/mcp.json").contains("ghp_") == false)
        #expect(fixture.text(".config/rv/secrets.json").contains("ghp_") == false)
        #expect(fixture.text(".config/rv/secrets.json").contains("GITHUB_PERSONAL_ACCESS_TOKEN"))

        let rv = fixture.home.appendingPathComponent("bin/rv")
        try FileManager.default.createDirectory(at: rv.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: rv.path, contents: Data())
        let setup = try MCPRun.setup(
            host: .cursor, names: [], project: nil, undo: false, rvPath: rv.path, environment: fixture.environment()
        ).get()
        #expect(setup.contains("routed through rv: github"))
        #expect(fixture.text(".cursor/mcp.json").contains("ghp_") == false)

        let after = try report(fixture, rvExecutable: rv.path)
        #expect(after.passes)
        #expect(MCPRun.listText(after, home: fixture.home).contains("governed"))
        let relative = try report(fixture, rvExecutable: "")
        #expect(relative.rows.contains { $0.name == "github" && $0.status == "governed" } == false)

        let undone = try MCPRun.setup(
            host: .cursor, names: [], project: nil, undo: true, rvPath: rv.path, environment: fixture.environment()
        ).get()
        #expect(undone.contains("restored github"))
        #expect(fixture.text(".cursor/mcp.json").contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    @Test func dryRunAndKeychainFailureWriteNothing() async throws {
        let fixture = Fixture()
        try fixture.write(".cursor/mcp.json", Self.cursorConfig)
        let dry = try await MCPRun.importServers(
            host: .cursor, names: ["github"], project: nil, allowTools: false, dryRun: true, environment: fixture.environment()
        ).get()
        #expect(dry.contains("dry run"))
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("mcp.json").path) == false)

        let refusing = SecretKeychainWriter(store: { _, _, _ in false }, delete: { _, _ in false })
        let failed = await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: fixture.environment(keychain: refusing))
        #expect(failed.failureMessage?.contains("nothing imported") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("mcp.json").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("secrets.json").path) == false)

        let unknown = await MCPRun.importServers(
            host: .cursor, names: ["nope"], project: nil, allowTools: false, dryRun: false, environment: fixture.environment())
        #expect(unknown.failureMessage == "cursor has no MCP server named nope")

        let huge = String(repeating: "a1", count: (SecretValue.maximumBytes / 2) + 1)
        try fixture.write(".cursor/mcp.json", #"{"mcpServers": {"gh": {"command": "npx", "env": {"GITHUB_TOKEN": "\#(huge)"}}}}"#)
        let rejected = await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false, environment: fixture.environment())
        #expect(rejected.failureMessage?.contains("nothing imported") == true)
        #expect(fixture.keychain.items.withLock { $0 }.isEmpty)

        let stored = Mutex(0)
        let partial = SecretKeychainWriter(
            store: { _, _, _ in
                stored.withLock { count in
                    count += 1
                    return count == 1
                }
            },
            delete: { _, _ in false })
        try fixture.write(".cursor/mcp.json", """
            {"mcpServers": {"gh": {"command": "npx", "env": {"GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789", "API_KEY": "sk-abcdefghijklmnopqrst"}}}}
            """)
        let failedSecond = await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: fixture.environment(keychain: partial))
        #expect(failedSecond.failureMessage?.contains("nothing imported") == false)
        #expect(failedSecond.failureMessage?.contains("already stored") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("mcp.json").path) == false)
    }

    @Test func importRefusesWithoutDeviceOwnerPresenceAndWritesNothing() async throws {
        let fixture = Fixture()
        try fixture.write(".cursor/mcp.json", Self.cursorConfig)
        let dry = try await MCPRun.importServers(
            host: .cursor, names: ["github"], project: nil, allowTools: false, dryRun: true,
            environment: fixture.environment(presence: Self.absent)
        ).get()
        #expect(dry.contains("dry run"))
        #expect(fixture.keychain.items.withLock { $0 }.isEmpty)

        let refused = await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: fixture.environment(presence: Self.absent))
        #expect(refused.failureMessage == "not imported: this process has no terminal; nothing imported")
        #expect(fixture.keychain.items.withLock { $0 }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("mcp.json").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("secrets.json").path) == false)
    }

    @Test func importShowsEveryServerURLAndSecretBindingBeforeWriting() async throws {
        let fixture = Fixture()
        let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        try fixture.write(".cursor/mcp.json", """
            {"mcpServers": {
              "api": {"url": "https://mcp.example/mcp", "headers": {"Authorization": "Bearer \(token)"}},
              "github": {"command": "npx", "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "\(token)"}}
            }}
            """)
        let shown = Mutex("")
        let promptedAfterReview = Mutex(false)
        let presence = UserPresence { reason, _ in
            let review = shown.withLock { $0 }
            promptedAfterReview.withLock { $0 = review.contains("https://mcp.example/mcp") && reason.contains("as shown") }
            return .refused("declined")
        }
        let dryShown = Mutex(false)
        let dry = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: true, dryRun: true,
            environment: fixture.environment(presence: presence), show: { _ in dryShown.withLock { $0 = true } }
        ).get()
        #expect(dry.contains("dry run"))
        #expect(dry.contains(token) == false)
        #expect(dryShown.withLock { $0 } == false)
        #expect(fixture.keychain.items.withLock { $0 }.isEmpty)

        let refused = await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: true, dryRun: false,
            environment: fixture.environment(presence: presence), show: { text in shown.withLock { $0 += text } })
        #expect(refused.failureMessage == "not imported: declined; nothing imported")
        let review = shown.withLock { $0 }
        #expect(review.contains("https://mcp.example/mcp"))
        #expect(review.contains("Authorization → secret API_AUTHORIZATION"))
        #expect(review.contains("GITHUB_PERSONAL_ACCESS_TOKEN → secret GITHUB_PERSONAL_ACCESS_TOKEN"))
        #expect(review.contains("tools will be allow"))
        #expect(review.contains(token) == false)
        #expect(promptedAfterReview.withLock { $0 })
        #expect(fixture.keychain.items.withLock { $0 }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("mcp.json").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("secrets.json").path) == false)
    }

    @Test func importShowsLiteralEnvironmentAndHeaderValuesBeforeConfirm() async throws {
        let fixture = Fixture()
        let password = "supersecretpassword"
        let database = "postgres://user:\(password)@db.example/app"
        try fixture.write(".cursor/mcp.json", """
            {"mcpServers": {
              "db": {"command": "db-mcp", "env": {"DATABASE_URL": "\(database)"}},
              "api": {"url": "https://mcp.example/mcp", "headers": {"X-Db": "\(database)"}}
            }}
            """)
        let shown = Mutex("")
        let presence = UserPresence { _, _ in
            let review = shown.withLock { $0 }
            if review.contains("DATABASE_URL=\(database)") && review.contains("X-Db: \(database)") {
                return .confirmed(method: "terminal confirmation")
            }
            return .refused("value was not shown")
        }
        let imported = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: fixture.environment(presence: presence), show: { text in shown.withLock { $0 += text } }
        ).get()
        let review = shown.withLock { $0 }
        #expect(review.contains("DATABASE_URL=\(database)"))
        #expect(review.contains("X-Db: \(database)"))
        #expect(review.contains(password))
        #expect(imported.contains("wrote mcp.json"))
        let signed = try String(contentsOf: fixture.config.appendingPathComponent("mcp.json"), encoding: .utf8)
        #expect(signed.contains(database))
        #expect(fixture.keychain.items.withLock { $0 }.isEmpty)
    }

    @Test func importRefusesASecretNestedInAQueryURL() async throws {
        let password = "supersecretpassword"
        let token = "ghp_1234567890abcdefghij"
        let urls = [
            "https://mcp.example/mcp?next=https://user:\(password)@evil.example/x",
            "https://mcp.example/mcp?next=https://evil.example/\(token)",
            "https://mcp.example/mcp?next=//user:\(password)@evil.example",
        ]
        for url in urls {
            let fixture = Fixture()
            try fixture.write(".cursor/mcp.json", #"{"mcpServers":{"api":{"url":"\#(url)"}}}"#)
            let shown = Mutex("")
            let result = try await MCPRun.importServers(
                host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
                environment: fixture.environment(presence: Self.present),
                show: { text in shown.withLock { $0 += text } }
            ).get()
            let review = shown.withLock { $0 }
            #expect(review.contains(password) == false)
            #expect(review.contains(token) == false)
            #expect(review.isEmpty)
            #expect(result.contains(password) == false)
            #expect(result.contains(token) == false)
            #expect(result.contains("nothing to import"))
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("mcp.json").path) == false)
        #expect(fixture.keychain.items.withLock { $0 }.isEmpty)
        }
    }

    @Test func importShowsLiteralArgsBeforeConfirmAndRefusesConcealedArgSecrets() async throws {
        let fixture = Fixture()
        let password = "supersecretpassword"
        let database = "postgres://user:\(password)@db.example/app"
        let databaseArg = "--database-url=\(database)"
        let cwdArg = "--cwd=\(database)"
        try fixture.write(".cursor/mcp.json", """
            {"mcpServers":{"db":{"command":"db-mcp","args":["\(databaseArg)","\(cwdArg)"]}}}
            """)
        let shown = Mutex("")
        let signed = fixture.config.appendingPathComponent("mcp.json")
        let presence = UserPresence { _, _ in
            let review = shown.withLock { $0 }
            let seen = review.contains("argument: \(databaseArg)") && review.contains("argument: \(cwdArg)")
                && review.contains(password)
            let notWritten = FileManager.default.fileExists(atPath: signed.path) == false
            if seen && notWritten { return .confirmed(method: "terminal confirmation") }
            return .refused("arg was not shown")
        }
        let imported = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: fixture.environment(presence: presence), show: { text in shown.withLock { $0 += text } }
        ).get()
        #expect(imported.contains("wrote mcp.json"))
        let stored = try String(contentsOf: signed, encoding: .utf8)
        #expect(stored.contains(databaseArg))
        #expect(stored.contains(cwdArg))

        let token = "ghp_1234567890abcdefghij"
        let refused = [
            "//user:\(password)@db.example/app",
            "--endpoint=//user:\(password)@db.example/app",
            "/opt/\(token)",
            "--config=/opt/\(token)",
        ]
        for arg in refused {
            let home = Fixture()
            let encoded = arg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            try home.write(".cursor/mcp.json", """
                {"mcpServers":{"db":{"command":"db-mcp","args":["\(encoded)"]}}}
                """)
            let review = Mutex("")
            let result = try await MCPRun.importServers(
                host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
                environment: home.environment(presence: Self.present),
                show: { text in review.withLock { $0 += text } }
            ).get()
            let text = review.withLock { $0 } + result
            #expect(text.contains(password) == false, "\(arg)")
            #expect(text.contains(token) == false, "\(arg)")
            #expect(result.contains("nothing to import"), "\(arg)")
            #expect(FileManager.default.fileExists(atPath: home.config.appendingPathComponent("mcp.json").path) == false)
        }
    }

    @Test func trustShowsEnvAndHeaderValuesBeforeSigning() async throws {
        let fixture = Fixture()
        let password = "supersecretpassword"
        let database = "postgres://user:\(password)@db.example/app"
        try fixture.write(".config/rv/mcp.json", """
            {"version":1,"servers":[
              {"name":"db","command":"db-mcp","env":{"DATABASE_URL":"\(database)"}},
              {"name":"api","url":"https://mcp.example/mcp","headers":{"X-Database":"\(database)"}}
            ]}
            """)
        chmod(fixture.home.appendingPathComponent(".config/rv/mcp.json").path, 0o600)
        chmod(fixture.config.path, 0o700)
        let environment = fixture.environment()
        #expect(environment.integrity.isTrusted == false)
        let shown = Mutex("")
        let presence = UserPresence { _, _ in
            let review = shown.withLock { $0 }
            let seen = review.contains("DATABASE_URL=\(database)") && review.contains("X-Database: \(database)")
                && review.contains(password)
            if seen && environment.integrity.isTrusted == false { return .confirmed(method: "terminal confirmation") }
            return .refused("value was not shown")
        }
        let trusted = try await MCPRun.trust(
            environment: fixture.environment(presence: presence), show: { text in shown.withLock { $0 += text } }
        ).get()
        #expect(trusted.contains("trusted mcp.json"))
        #expect(fixture.environment().integrity == .trusted)
        let review = shown.withLock { $0 }
        #expect(review.contains("(literal)") == false)
    }

    @Test func trustRefusesARepeatedDatabaseUrl() async throws {
        let password = "supersecretpassword"
        let database = "postgres://user:\(password)@db.example/app"
        let documents = [
            #"{"version":1,"servers":[{"name":"db","command":"db-mcp","env":{"DATABASE_URL":"\#(database)","DATABASE_URL":"ok"}}]}"#,
            #"{"version":1,"servers":[{"name":"db","command":"db-mcp","args":["--database-url=\#(database)"],"args":["--help"]}]}"#,
            #"{"version":1,"servers":[{"name":"api","url":"https://mcp.example/mcp","headers":{"X-Database":"\#(database)","X-Database":"ok"}}]}"#,
        ]
        for document in documents {
            let fixture = Fixture()
            try fixture.write(".config/rv/mcp.json", document)
            chmod(fixture.home.appendingPathComponent(".config/rv/mcp.json").path, 0o600)
            chmod(fixture.config.path, 0o700)
            let shown = Mutex("")
            let result = await MCPRun.trust(
                environment: fixture.environment(presence: Self.present),
                show: { text in shown.withLock { $0 += text } }
            )
            let message = result.failureMessage ?? ""
            #expect(message.contains("repeats a JSON key"), "\(message)")
            #expect(message.contains("nothing signed"), "\(message)")
            #expect(message.contains(password) == false, "\(message)")
            #expect(shown.withLock { $0 }.contains(password) == false)
            #expect(fixture.environment().integrity.isTrusted == false)
        }
    }

    @Test func trustShowsTheFifthToolGlobBeforeSigning() async throws {
        let fixture = Fixture()
        let password = "supersecretpassword"
        let database = "postgres://user:\(password)@db.example/app"
        let writable = "/opt/ghp_1234567890abcdefghij"
        try fixture.write(".config/rv/mcp.json", """
            {"version":1,"servers":[{"name":"db","command":"db-mcp",
              "description":"\(database)",
              "secrets":{"DATABASE_URL":"\(password)"},
              "sandbox":{"network":false,"writable":["\(writable)"]},
              "tools":{"allow":["a","b","c","d","\(database)"]}}]}
            """)
        chmod(fixture.home.appendingPathComponent(".config/rv/mcp.json").path, 0o600)
        chmod(fixture.config.path, 0o700)
        let environment = fixture.environment()
        let shown = Mutex("")
        let presence = UserPresence { _, _ in
            let review = shown.withLock { $0 }
            let seen = review.contains("    allow \(database)")
                && review.contains("+1 more") == false
                && review.contains("    description: \(database)")
                && review.contains("    writable: \(writable)")
                && review.contains("    DATABASE_URL → secret \(password)")
                && review.contains(password)
            if seen && environment.integrity.isTrusted == false { return .confirmed(method: "terminal confirmation") }
            return .refused("value was not shown")
        }
        let trusted = try await MCPRun.trust(
            environment: fixture.environment(presence: presence), show: { text in shown.withLock { $0 += text } }
        ).get()
        #expect(trusted.contains("trusted mcp.json"))
        #expect(fixture.environment().integrity == .trusted)
    }

    @Test func trustShowsAPasswordThatContainsACarriageReturn() async throws {
        let fixture = Fixture()
        let json = #"{"version":1,"servers":[{"name":"db","command":"db-mcp","env":{"DATABASE_URL":"postgres://user:super\rsecretpassword@db.example/app"}}]}"#
        try fixture.write(".config/rv/mcp.json", json)
        chmod(fixture.home.appendingPathComponent(".config/rv/mcp.json").path, 0o600)
        chmod(fixture.config.path, 0o700)
        let environment = fixture.environment()
        let shown = Mutex("")
        let escaped = "postgres://user:super\\rsecretpassword@db.example/app"
        let presence = UserPresence { _, _ in
            let review = shown.withLock { $0 }
            let seen = review.contains(escaped) && review.contains("secretpassword")
                && review.contains("\r") == false && review.contains("\u{1B}") == false
            if seen && environment.integrity.isTrusted == false { return .confirmed(method: "terminal confirmation") }
            return .refused("value was not shown")
        }
        let trusted = try await MCPRun.trust(
            environment: fixture.environment(presence: presence), show: { text in shown.withLock { $0 += text } }
        ).get()
        #expect(trusted.contains("trusted mcp.json"))
        #expect(shown.withLock { $0 }.contains(escaped))

        let hidden = "\u{1B}[8mpostgres://user:supersecretpassword@db.example/app\u{1B}[28m"
        let remote = MCPRemoteServer(
            url: try #require(URL(string: "https://mcp.example/mcp")), headers: ["X-Database": hidden])
        let review = MCPRun.trustReview(MCPConfiguration(servers: [MCPServerDefinition(name: "api", remote: remote)]))
        #expect(review.contains("\\u{001B}[8m"))
        #expect(review.contains("supersecretpassword"))
        #expect(review.contains("\u{1B}") == false)
        #expect(MCPRun.trustReviewShowsEveryLiteral(
            MCPConfiguration(servers: [MCPServerDefinition(name: "api", remote: remote)]), review))

        let home = Fixture()
        try home.write(".cursor/mcp.json", #"{"mcpServers":{"db":{"command":"db-mcp","env":{"DATABASE_URL":"postgres://user:super\rsecretpassword@db.example/app"}}}}"#)
        let importedReview = Mutex("")
        let importing = UserPresence { _, _ in
            let text = importedReview.withLock { $0 }
            let seen = text.contains(escaped) && text.contains("description:") && text.contains("imported from cursor")
                && text.contains("\r") == false
            if seen { return .confirmed(method: "terminal confirmation") }
            return .refused("value was not shown")
        }
        let imported = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: home.environment(presence: importing),
            show: { text in importedReview.withLock { $0 += text } }
        ).get()
        #expect(imported.contains("import db"))
        #expect(importedReview.withLock { $0 }.contains(escaped))
    }

    @Test func trustEscapesC1AndBidiBeforeSigning() async throws {
        let password = "supersecretpassword"
        let database = "postgres://user:\(password)@db.example/app"
        let c1Document = """
            {"version":1,"servers":[
              {"name":"db","command":"db-mcp","env":{"DATABASE_URL":"\(database)\\u009b2K"}},
              {"name":"api","url":"https://mcp.example/mcp","headers":{"X-Database":"\\u009b8m\(database)\\u009b28m"}}
            ]}
            """
        try await expectEscapedControl(
            c1Document, marker: "\\u{009B}", raw: "\u{009B}", password: password)

        let bidiDocument = """
            {"version":1,"servers":[{"name":"db","command":"db-mcp\\u202E\(database)",
              "description":"ok\\u202E\(database)",
              "args":["ok\\u202E\(database)"],
              "env":{"DATABASE_URL":"ok\\u202E\(database)"},
              "sandbox":{"network":false,"writable":["~/ok\\u202E\(database)"]},
              "tools":{"allow":["a","b","c","d","ok\\u202E\(database)"]}}]}
            """
        try await expectEscapedControl(
            bidiDocument, marker: "\\u{202E}", raw: "\u{202E}", password: password)

        let lineDocument = """
            {"version":1,"servers":[{"name":"db","command":"db-mcp",
              "description":"ok\\u2028sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
              "env":{"DATABASE_URL":"\(database)\\u2029"}}]}
            """
        try await expectEscapedControl(
            lineDocument, marker: "\\u{2028}", raw: "\u{2028}", password: password)
        try await expectEscapedControl(
            lineDocument, marker: "\\u{2029}", raw: "\u{2029}", password: password)

        let marks: [(String, Character)] = [("\\u061C", "\u{061C}"), ("\\u200E", "\u{200E}"), ("\\u200F", "\u{200F}")]
        for (escaped, raw) in marks {
            let document = """
                {"version":1,"servers":[{"name":"db","command":"db-mcp",
                  "description":"https://good.example/mcp\(escaped)@evil.example",
                  "env":{"DATABASE_URL":"\(database)"}}]}
                """
            let marker = "\\u{\(String(format: "%04X", raw.unicodeScalars.first!.value))}"
            try await expectEscapedControl(document, marker: marker, raw: raw, password: password)
        }
    }

    private func expectEscapedControl(
        _ document: String, marker: String, raw: Character, password: String
    ) async throws {
        let fixture = Fixture()
        try fixture.write(".config/rv/mcp.json", document)
        chmod(fixture.home.appendingPathComponent(".config/rv/mcp.json").path, 0o600)
        chmod(fixture.config.path, 0o700)
        let environment = fixture.environment()
        let shown = Mutex("")
        let presence = UserPresence { _, _ in
            let review = shown.withLock { $0 }
            let seen = review.contains(password) && review.contains(marker) && review.contains(raw) == false
                && review.contains("sha256: ")
            if seen && environment.integrity.isTrusted == false { return .confirmed(method: "terminal confirmation") }
            return .refused("value was not shown")
        }
        let trusted = try await MCPRun.trust(
            environment: fixture.environment(presence: presence), show: { text in shown.withLock { $0 += text } }
        ).get()
        #expect(trusted.contains("trusted mcp.json"))
        let review = shown.withLock { $0 }
        #expect(review.contains(marker))
        #expect(review.contains(raw) == false)
        let signed = fixture.approvalEvents().last?.detail["sha256"]
        let shownHash = review.split(separator: "\n").first { $0.hasPrefix("sha256: ") }.map {
            String($0.dropFirst("sha256: ".count))
        }
        #expect(shownHash == signed)
        #expect(shownHash?.isEmpty == false)
    }

    @Test func importRefusesATokenPrefixThatHidesAnotherSecret() async throws {
        let token = "ghp_1234567890abcdefghij"
        let password = "supersecretpassword"
        let hidden = [
            #"["ctx7sk-12345678/opt/\#(token)"]"#,
            #"["sk-12345678#\#(token)"]"#,
            #"["--api-key","ctx7sk-12345678/opt/\#(token)"]"#,
            #"["ctx7sk-12345678:\#(password)@collector.example"]"#,
            #"["ctx7sk-12345678;\#(token)"]"#,
            #"["\#(token)/opt/notes"]"#,
            #"["\#(token)//user:\#(password)@collector.example"]"#,
            #"["%67hp_1234567890abcdefghij//user:\#(password)@collector.example"]"#,
            #"["%67hp_1234567890abcdefghij"]"#,
            #"["/:\#(password)@collector.example"]"#,
            #"["user:\#(password)@collector.example"]"#,
            #"["user%3A\#(password)%40collector.example"]"#,
            #"["user:su%26\#(password)@collector.example"]"#,
            #"["user:su&\#(password)@collector.example"]"#,
            #"["user:su \#(password)@collector.example"]"#,
            #"["user:su#\#(password)@collector.example"]"#,
            #"["user:su?\#(password)@collector.example"]"#,
            #"["/:su%5C\#(password)@collector.example"]"#,
            #"["--file=/:su%5C\#(password)@collector.example"]"#,
            #"["/:su%2F\#(password)@collector.example"]"#,
            #"["user:\#(password)@collector.example://x"]"#,
            #"["/:\#(password)@collector.example://x"]"#,
            #"["user%3A\#(password)%40collector.example://x"]"#,
            #"["%\#(String(repeating: "25", count: 64))67hp_1234567890abcdefghij"]"#,
            #"["ctx7sk-12345678=\#(token)"]"#,
            #"["sk-12345678=\#(token)"]"#,
            #"["\#(token)=sk-1234567890abcdef"]"#,
            #"["ctx7sk-12345678-\#(token)"]"#,
            #"["sk-12345678+\#(token)"]"#,
            #"["https://example.com/?token=\#(token)%"]"#,
            #"["https://example.com/?token=%67hp_1234567890abcdefghij%"]"#,
            #"["--endpoint=https://example.com/?token=\#(token)%"]"#,
            #"["http://127.0.0.1/:\#(password)@collector.example"]"#,
            #"["ingest%\#(String(repeating: "25", count: 64))09\#(token)"]"#,
            #"["ingest%\#(String(repeating: "25", count: 64))0A\#(token)"]"#,
            #"["ingest%\#(String(repeating: "25", count: 64))0D\#(token)"]"#,
            #"["user:su%2F\#(password)@collector.example"]"#,
            #"["user:su%5C\#(password)@collector.example"]"#,
            #"["/:%2F\#(password)@collector.example"]"#,
            #"["/:%5C\#(password)@collector.example"]"#,
            #"["user:su%2F\#(password)@collector.example://x"]"#,
            #"["http://127.0.0.1/:%2F\#(password)@collector.example"]"#,
            #"["http://127.0.0.1/user:su%2F\#(password)@collector.example"]"#,
            #"["ctx7sk-12345678_\#(token)"]"#,
            #"["ctx7sk-12345678*\#(token)"]"#,
            #"["in+ghp_12345678"]"#,
            #"["https://example.com/?token=%22\#(token)%"]"#,
            #"["https://example.com/?token=%22%67hp_1234567890abcdefghij%"]"#,
            #"["--endpoint=https://example.com/?token=%22\#(token)%"]"#,
            #"["x_ghp_12345678"]"#,
            #"["x+ghp_12345678"]"#,
            #"["x-ghp_12345678"]"#,
            #"["stdio://srv?t=x_ghp_12345678"]"#,
            #"["wss://example.com/x_ghp_12345678"]"#,
            #"["postgres://user:x_ghp_12345678@db.example/app"]"#,
            #"["--api-key=ctx7sk-12345678_\#(token)"]"#,
            #"["user~:su&\#(password)@collector.example"]"#,
            #"["user:su/\#(password)@collector.example"]"#,
            #"["user:su\\\#(password)@collector.example"]"#,
            #"["user:%2F\#(password)@collector.example"]"#,
            #"["user:/\#(password)@collector.example"]"#,
            #"["user~:/\#(password)@collector.example"]"#,
            #"["user+:%2F\#(password)@collector.example"]"#,
            #"["user!:/\#(password)@collector.example"]"#,
            #"["user:\\#(password)@collector.example"]"#,
            #"["wss://example.com/user:/\#(password)@collector.example"]"#,
            #"["postgres://db.example/user:/\#(password)@collector.example"]"#,
            #"["ctx7sk-12345678^\#(token)"]"#,
            #"["sk-12345678^\#(token)"]"#,
            #"["ctx7sk-12345678!\#(token)"]"#,
            #"["ctx7sk-12345678%\#(token)"]"#,
            #"["ctx7sk-12345678＿\#(token)"]"#,
            #"["ctx7sk-12345678_xghp_12345678"]"#,
            #"["user://\#(password)@collector.example"]"#,
            #"["user:\/\#(password)@collector.example"]"#,
            #"["user:/\\\#(password)@collector.example"]"#,
            #"["user:%2F%2F\#(password)@collector.example"]"#,
            #"["user:%5C%5C\#(password)@collector.example"]"#,
            #"["user:%2F%5C\#(password)@collector.example"]"#,
            #"["user:%5C%2F\#(password)@collector.example"]"#,
            #"["user:/%2F\#(password)@collector.example"]"#,
            #"["user:/%5C\#(password)@collector.example"]"#,
            #"["wss://example.com/user://\#(password)@collector.example"]"#,
            #"["postgres://db.example/user://\#(password)@collector.example"]"#,
            #"["postgres://user://\#(password)@db.example/app"]"#,
            #"["wss://example.com/user:/%2F\#(password)@collector.example"]"#,
            #"["postgres://db.example/user:/%2F\#(password)@collector.example"]"#,
            #"["user:@\#(password)@collector.example"]"#,
            #"["wss://example.com/user:@\#(password)@collector.example"]"#,
            #"["postgres://db.example/user:@\#(password)@collector.example"]"#,
            #"["ctx7sk-12345678g\#("\u{200B}")hp_12345678"]"#,
            #"["sk-12345678g\#("\u{200B}")hp_12345678"]"#,
            #"["--api-key","ctx7sk-12345678g\#("\u{200B}")hp_12345678"]"#,
            #"["ctx7sk-12345678g\#("\u{200C}")hp_12345678"]"#,
            #"["ctx7sk-12345678g\#("\u{200D}")hp_12345678"]"#,
            #"["ctx7sk-12345678g\#("\u{FEFF}")hp_12345678"]"#,
            #"["ctx7sk-12345678g\#("\u{2060}")hp_12345678"]"#,
            #"["ctx7sk-12345678g%E2%80%8Bhp_12345678"]"#,
            #"["ctx7sk-12345678g\#("\u{200E}")hp_12345678"]"#,
            #"["--api-key","ctx7sk-12345678g\#("\u{200E}")hp_12345678"]"#,
            #"["ctx7sk-12345678g\#("\u{200F}")hp_12345678"]"#,
            #"["ctx7sk-12345678g\#("\u{061C}")hp_12345678"]"#,
            #"["sk-12345678g\#("\u{200E}")hp_12345678"]"#,
            #"["ctx7sk-12345678g\#("\u{2063}")hp_12345678"]"#,
            #"["ctx7sk-12345678g\#("\u{180E}")hp_12345678"]"#,
            #"["ctx7sk-12345678g\#("\u{00A0}")hp_1234567890abcdefghij"]"#,
            #"["ctx7sk-12345678g%E2%80%8Ehp_12345678"]"#,
            #"["ctx7sk-12345678g\#("\u{00AD}")hp_12345678"]"#,
            #"["--api-key","ctx7sk-12345678g\#("\u{00AD}")hp_12345678"]"#,
            #"["ctx7sk-12345678g%C2%ADhp_12345678"]"#,
            #"["wss://example.com/http://\#(password)@collector.example"]"#,
            #"["wss://example.com/https://\#(password)@collector.example"]"#,
            #"["postgres://db.example/http://\#(password)@collector.example"]"#,
            #"["postgres://db.example/https://\#(password)@collector.example"]"#,
            #"["postgres://http://\#(password)@db.example/app"]"#,
            #"["--cwd=wss://example.com/http://\#(password)@collector.example"]"#,
            #"["wss://example.com/http:%5C%5C\#(password)@collector.example"]"#,
            #"["wss://example.com/https:%5C%5C\#(password)@collector.example"]"#,
        ]
        for args in hidden {
            let home = Fixture()
            try home.write(".cursor/mcp.json", #"{"mcpServers":{"db":{"command":"db-mcp","args":\#(args)}}}"#)
            let review = Mutex("")
            let result = try await MCPRun.importServers(
                host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
                environment: home.environment(presence: Self.present),
                show: { text in review.withLock { $0 += text } }
            ).get()
            let text = review.withLock { $0 } + result
            #expect(text.contains(token) == false, "\(args)")
            #expect(text.contains("ghp_") == false, "\(args)")
            #expect(text.contains("${secret:") == false, "\(args)")
            #expect(text.contains(password) == false, "\(args)")
            #expect(result.contains("nothing to import"), "\(args)")
            #expect(FileManager.default.fileExists(atPath: home.config.appendingPathComponent("mcp.json").path) == false)
            #expect(home.keychain.items.withLock { $0 }.isEmpty)
        }

        let commandHome = Fixture()
        try commandHome.write(
            ".cursor/mcp.json",
            #"{"mcpServers":{"db":{"command":"https://mcp.example/sse?token=\#(token)"}}}"#)
        let commandResult = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: commandHome.environment(presence: Self.present), show: { _ in }
        ).get()
        #expect(commandResult.contains("nothing to import"))
        #expect(commandResult.contains(token) == false)
        #expect(FileManager.default.fileExists(atPath: commandHome.config.appendingPathComponent("mcp.json").path) == false)
        #expect(commandHome.keychain.items.withLock { $0 }.isEmpty)

        let slashCommand = Fixture()
        try slashCommand.write(
            ".cursor/mcp.json",
            #"{"mcpServers":{"db":{"command":"https://mcp.example/sse?next=user:%2F\#(password)@collector.example"}}}"#)
        let slashResult = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: slashCommand.environment(presence: Self.present), show: { _ in }
        ).get()
        #expect(slashResult.contains("nothing to import"))
        #expect(slashResult.contains(password) == false)
        #expect(FileManager.default.fileExists(atPath: slashCommand.config.appendingPathComponent("mcp.json").path) == false)
        #expect(slashCommand.keychain.items.withLock { $0 }.isEmpty)

        let rawSlashCommand = Fixture()
        try rawSlashCommand.write(
            ".cursor/mcp.json",
            #"{"mcpServers":{"db":{"command":"https://mcp.example/sse?next=user:/\#(password)@collector.example"}}}"#)
        let rawSlashResult = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: rawSlashCommand.environment(presence: Self.present), show: { _ in }
        ).get()
        #expect(rawSlashResult.contains("nothing to import"))
        #expect(rawSlashResult.contains(password) == false)
        #expect(FileManager.default.fileExists(atPath: rawSlashCommand.config.appendingPathComponent("mcp.json").path) == false)
        #expect(rawSlashCommand.keychain.items.withLock { $0 }.isEmpty)

        let doubleSlashCommand = Fixture()
        try doubleSlashCommand.write(
            ".cursor/mcp.json",
            #"{"mcpServers":{"db":{"command":"https://mcp.example/sse?next=user://su&\#(password)@collector.example"}}}"#)
        let doubleSlashResult = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: doubleSlashCommand.environment(presence: Self.present), show: { _ in }
        ).get()
        #expect(doubleSlashResult.contains("nothing to import"))
        #expect(doubleSlashResult.contains(password) == false)
        #expect(doubleSlashResult.contains("${secret:") == false)
        #expect(doubleSlashCommand.keychain.items.withLock { $0 }.isEmpty)

        let encodedSlashCommand = Fixture()
        try encodedSlashCommand.write(
            ".cursor/mcp.json",
            #"{"mcpServers":{"db":{"command":"https://mcp.example/sse?next=user:/%2Fsu&\#(password)@collector.example"}}}"#)
        let encodedSlashResult = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: encodedSlashCommand.environment(presence: Self.present), show: { _ in }
        ).get()
        #expect(encodedSlashResult.contains("nothing to import"))
        #expect(encodedSlashResult.contains(password) == false)
        #expect(encodedSlashCommand.keychain.items.withLock { $0 }.isEmpty)
    }

    @Test func importRefusesASecondPrefixInEnvAndHeaders() async throws {
        let token = "ghp_1234567890abcdefghij"
        let envValues = [
            "ctx7sk-12345678^\(token)",
            "ctx7sk-12345678!\(token)",
            "ctx7sk-12345678%\(token)",
            "ctx7sk-12345678＿\(token)",
            "ctx7sk-12345678_xghp_12345678",
        ]
        for value in envValues {
            for variable in ["GITHUB_TOKEN", "LOG_LEVEL"] {
                let home = Fixture()
                let encoded = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                try home.write(
                    ".cursor/mcp.json",
                    #"{"mcpServers":{"db":{"command":"db-mcp","env":{"\#(variable)":"\#(encoded)"}}}}"#)
                let review = Mutex("")
                let result = try await MCPRun.importServers(
                    host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
                    environment: home.environment(presence: Self.present),
                    show: { text in review.withLock { $0 += text } }
                ).get()
                let text = review.withLock { $0 } + result
                #expect(text.contains(token) == false, "\(variable)")
                #expect(text.contains("ghp_") == false, "\(variable)")
                #expect(text.contains("${secret:") == false, "\(variable) \(text)")
                #expect(result.contains("nothing to import"), "\(variable)")
                #expect(home.keychain.items.withLock { $0 }.isEmpty)
            }
        }

        let bearer = Fixture()
        try bearer.write(
            ".cursor/mcp.json",
            #"{"mcpServers":{"api":{"url":"https://mcp.example/mcp","headers":{"Authorization":"Bearer ctx7sk-12345678^\#(token)"}}}}"#)
        let bearerReview = Mutex("")
        let bearerResult = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: bearer.environment(presence: Self.present),
            show: { text in bearerReview.withLock { $0 += text } }
        ).get()
        let bearerText = bearerReview.withLock { $0 } + bearerResult
        #expect(bearerText.contains(token) == false)
        #expect(bearerText.contains("${secret:") == false, "\(bearerText)")
        #expect(bearerResult.contains("nothing to import"))
        #expect(bearer.keychain.items.withLock { $0 }.isEmpty)

        let apiKey = Fixture()
        try apiKey.write(
            ".cursor/mcp.json",
            #"{"mcpServers":{"api":{"url":"https://mcp.example/mcp","headers":{"X-API-Key":"sk-12345678^\#(token)"}}}}"#)
        let apiResult = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: apiKey.environment(presence: Self.present), show: { _ in }
        ).get()
        #expect(apiResult.contains(token) == false)
        #expect(apiResult.contains("${secret:") == false)
        #expect(apiResult.contains("nothing to import"))
        #expect(apiKey.keychain.items.withLock { $0 }.isEmpty)
    }

    @Test func importRefusesASecondPrefixThatDoesNotLookLikeOneToken() async throws {
        let token = "ghp_1234567890abcdefghij"
        let envValues = [
            "ctx7sk-12345678%20^\(token)",
            "ctx7sk-12345678%20%67hp_1234567890abcdefghij",
            "xctx7sk-12345678^\(token)",
            " ctx7sk-12345678^\(token)",
            "ctx7sk-12345678 ^\(token)",
            "ctx7sk-12345678://\(token)",
            ".ctx7sk-12345678^\(token)",
            "%2Ectx7sk-12345678^\(token)",
            "ctx7sk-12345678%3A%2F%2F\(token)",
            "ctx7sk-12345678g\u{200E}hp_1234567890abcdefghij",
            "ctx7sk-12345678g\u{200F}hp_1234567890abcdefghij",
            "ctx7sk-12345678g\u{061C}hp_1234567890abcdefghij",
            "ctx7sk-12345678g\u{2063}hp_1234567890abcdefghij",
            "ctx7sk-12345678g\u{180E}hp_1234567890abcdefghij",
            "ctx7sk-12345678g\u{00A0}hp_1234567890abcdefghij",
            "ctx7sk-12345678g\u{2061}hp_1234567890abcdefghij",
            "ctx7sk-12345678g\u{202A}hp_1234567890abcdefghij",
            "ctx7sk-12345678g%E2%80%8Ehp_1234567890abcdefghij",
            "ctx7sk-12345678g\u{00AD}hp_12345678",
            "ctx7sk-12345678g%C2%ADhp_12345678",
        ]
        for value in envValues {
            for variable in ["GITHUB_TOKEN", "LOG_LEVEL"] {
                let home = Fixture()
                let encoded = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                try home.write(
                    ".cursor/mcp.json",
                    #"{"mcpServers":{"db":{"command":"db-mcp","env":{"\#(variable)":"\#(encoded)"}}}}"#)
                let review = Mutex("")
                let result = try await MCPRun.importServers(
                    host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
                    environment: home.environment(presence: Self.present),
                    show: { text in review.withLock { $0 += text } }
                ).get()
                let text = review.withLock { $0 } + result
                #expect(text.contains(token) == false, "\(variable) \(value)")
                #expect(text.contains("ghp_") == false, "\(variable)")
                #expect(text.contains("${secret:") == false, "\(variable) \(text)")
                #expect(result.contains("nothing to import"), "\(variable)")
                #expect(home.keychain.items.withLock { $0 }.isEmpty)
            }
        }

        let headers: [(String, String)] = [
            ("Authorization", "Bearer ctx7sk-12345678%20^\(token)"),
            ("Authorization", "Bearer%20ctx7sk-12345678^\(token)"),
            ("Authorization", "Bearer xctx7sk-12345678^\(token)"),
            ("Authorization", "Bearer ctx7sk-12345678g\u{200E}hp_1234567890abcdefghij"),
            ("X-API-Key", "sk-12345678%20^\(token)"),
            ("X-API-Key", "sk-12345678%20%67hp_1234567890abcdefghij"),
            ("X-API-Key", "xsk-12345678^\(token)"),
            ("X-API-Key", "sk-12345678g\u{2063}hp_1234567890abcdefghij"),
            ("X-API-Key", "sk-12345678g\u{00A0}hp_1234567890abcdefghij"),
            ("Cookie", "ctx7sk-12345678%20^\(token)"),
            ("Cookie", "ctx7sk-12345678g\u{180E}hp_1234567890abcdefghij"),
            ("Proxy-Authorization", "Basic\u{00A0}ctx7sk-12345678^\(token)"),
            ("Authorization", "Bearer ctx7sk-12345678g\u{00AD}hp_12345678"),
            ("Authorization", "Bearer ctx7sk-12345678g%C2%ADhp_12345678"),
            ("X-API-Key", "ctx7sk-12345678g\u{00AD}hp_12345678"),
            ("X-API-Key", "ctx7sk-12345678g%C2%ADhp_12345678"),
        ]
        for (header, value) in headers {
            let home = Fixture()
            let encoded = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            try home.write(
                ".cursor/mcp.json",
                #"{"mcpServers":{"api":{"url":"https://mcp.example/mcp","headers":{"\#(header)":"\#(encoded)"}}}}"#)
            let review = Mutex("")
            let result = try await MCPRun.importServers(
                host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
                environment: home.environment(presence: Self.present),
                show: { text in review.withLock { $0 += text } }
            ).get()
            let text = review.withLock { $0 } + result
            #expect(text.contains(token) == false, "\(header)")
            #expect(text.contains("ghp_") == false, "\(header) \(text)")
            #expect(text.contains("${secret:") == false, "\(header) \(text)")
            #expect(result.contains("nothing to import"), "\(header) \(text)")
            #expect(home.keychain.items.withLock { $0 }.isEmpty)
        }

        let tabbed = Fixture()
        try tabbed.write(
            ".cursor/mcp.json",
            #"{"mcpServers":{"api":{"url":"https://mcp.example/mcp","headers":{"Authorization":"Bearer\tctx7sk-12345678^\#(token)"}}}}"#)
        let tabbedReview = Mutex("")
        let tabbedResult = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: tabbed.environment(presence: Self.present),
            show: { text in tabbedReview.withLock { $0 += text } }
        ).get()
        let tabbedText = tabbedReview.withLock { $0 } + tabbedResult
        #expect(tabbedText.contains(token) == false, "\(tabbedText)")
        #expect(tabbedText.contains("ghp_") == false, "\(tabbedText)")
        #expect(tabbedText.contains("${secret:") == false, "\(tabbedText)")
        #expect(tabbedResult.contains("nothing to import"))
        #expect(tabbed.keychain.items.withLock { $0 }.isEmpty)

        let jsonEscape = Fixture()
        try jsonEscape.write(
            ".cursor/mcp.json",
            #"{"mcpServers":{"db":{"command":"db-mcp","env":{"GITHUB_TOKEN":"ctx7sk-12345678g\u200ehp_1234567890abcdefghij"}}}}"#)
        let escapeResult = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: jsonEscape.environment(presence: Self.present), show: { _ in }
        ).get()
        #expect(escapeResult.contains("ghp_") == false)
        #expect(escapeResult.contains("${secret:") == false)
        #expect(escapeResult.contains("nothing to import"))
        #expect(jsonEscape.keychain.items.withLock { $0 }.isEmpty)
    }

    private func hostJSON(_ name: String, _ fields: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": [name: fields]])
        return String(decoding: data, as: UTF8.self)
    }

    private func expectImportRefused(_ document: String, absent: [String], label: String) async throws {
        let home = Fixture()
        try home.write(".cursor/mcp.json", document)
        let review = Mutex("")
        let result = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: home.environment(presence: Self.present),
            show: { text in review.withLock { $0 += text } }
        ).get()
        let text = review.withLock { $0 } + result
        let written = home.text(".config/rv/mcp.json")
        let storedReference = text.replacingOccurrences(of: "${secret:NAME}", with: "")
        #expect(result.contains("nothing to import"), "\(label) \(text)")
        #expect(storedReference.contains("${secret:") == false, "\(label) \(text)")
        #expect(home.keychain.items.withLock { $0 }.isEmpty, "\(label)")
        #expect(FileManager.default.fileExists(atPath: home.config.appendingPathComponent("mcp.json").path) == false, "\(label)")
        for piece in absent {
            #expect(text.contains(piece) == false, "\(label)")
            #expect(written.contains(piece) == false, "\(label)")
        }
    }

    @Test func importRefusesAPasswordSittingInTheAuthority() async throws {
        let password = "supersecretpassword"
        let encodedSchemes = [
            "%68%74%74%70%3A%2F%2F\(password)%40collector.example%2Fhook",
            "http:%2F%2F\(password)%40collector.example/hook",
            "https:%2F%2F\(password)%40collector.example/hook",
            "HTTPS:%2F%2F\(password)%40collector.example/hook",
        ]
        let encodedAt = [
            "https://\(password)%40collector.example/hook",
            "https://\(password)%2540collector.example/hook",
            "HTTPS://\(password)%40collector.example/hook",
            "wss://\(password)%40collector.example/hook",
            "postgres://\(password)%40db.example/app",
        ]
        let raw = "https://\(password)@collector.example/hook"
        for value in encodedSchemes + encodedAt + [raw] {
            try await expectImportRefused(
                #"{"mcpServers":{"db":{"command":"\#(value)"}}}"#,
                absent: [password], label: "command")
            try await expectImportRefused(
                #"{"mcpServers":{"db":{"command":"db-mcp","args":["\#(value)","--cwd=\#(value)"]}}}"#,
                absent: [password], label: "argument")
        }
        let remotes = [
            "https://\(password)%40evil.example/hook",
            "https://\(password)%2540evil.example/hook",
            "HTTPS://\(password)%40evil.example/hook",
            "https://\(password)@evil.example/hook",
        ]
        for url in remotes {
            try await expectImportRefused(
                #"{"mcpServers":{"api":{"url":"\#(url)"}}}"#,
                absent: [password], label: "remote")
        }
        let encodedDelimiters = [
            "https://\(password)%2F@collector.example/hook",
            "https://\(password)%2f@collector.example/hook",
            "https://\(password)%5C@collector.example/hook",
            "https://\(password)%3F@collector.example/hook",
            "https://\(password)%23@collector.example/hook",
            "https://\(password)%252F@collector.example/hook",
            "http://\(password)%2F@collector.example/hook",
            "HTTPS://\(password)%2F@collector.example/hook",
            "wss://\(password)%2F@collector.example/hook",
            "postgres://\(password)%2F@db.example/app",
            "https:%2F%2F\(password)%2F@collector.example/hook",
        ]
        for value in encodedDelimiters {
            try await expectImportRefused(
                #"{"mcpServers":{"db":{"command":"\#(value)"}}}"#,
                absent: [password], label: "delimiter command")
            try await expectImportRefused(
                #"{"mcpServers":{"db":{"command":"db-mcp","args":["\#(value)","--cwd=\#(value)","--database-url=\#(value)"]}}}"#,
                absent: [password], label: "delimiter argument")
        }
        let passwordGaps = [
            "https://\(password)%2F%2F@collector.example/hook",
            "https://\(password)%2Fx@collector.example/hook",
            "https://\(password)%5Cx@collector.example/hook",
            "https://\(password)%3Fx@collector.example/hook",
            "https://\(password)%23x@collector.example/hook",
            "https://\(password)%252F%252F@collector.example/hook",
            "https://%2F\(password)@collector.example/hook",
            "https://\(password)%2F%E2%80%8B@collector.example/hook",
            "https:%2F%2F\(password)%2F%2F@collector.example/hook",
            "https://\(password)%2F@localhost/hook",
            "postgres://\(password)%2F@db/app",
            "https://\(password)%2F@[::1]/hook",
            "https://\(password)%2F@collector\u{3002}example/hook",
            "https://%3A\(password)@collector.example/hook",
            "https://:\(password)@collector.example/hook",
            "https://\\\(password)@collector.example/hook",
            "wss://\\\(password)@collector.example/hook",
            "https://\\\(password)@localhost/hook",
            "postgres://\\\(password)@db/app",
            "https://\(password)\\x@collector.example/hook",
            "https://\(password)\\\\@collector.example/hook",
            "postgres://\(password)\\x@db.example/app",
            "postgres://\(password)\\\\@collector.example/hook",
            "wss://\(password)\\x@collector.example/hook",
            "https://\(password)\\@localhost/hook",
            "https://\(password)\\@db/hook",
            "https://\(password)\\@[::1]/hook",
            "https://\(password)\\@collector\u{3002}example/hook",
            "postgres://\(password)\\@db/app",
            "https://\t:\(password)@collector.example/hook",
            "https://\n:\(password)@collector.example/hook",
            "https://\r:\(password)@collector.example/hook",
        ]
        for value in passwordGaps {
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: [password], label: "userinfo command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": [value, "--cwd=\(value)", "--database-url=\(value)"]]),
                absent: [password], label: "userinfo argument")
        }
    }

    @Test func importRefusesASchemeBackslashAndAnExtenderOnAt() async throws {
        let password = "supersecretpassword"
        let schemeBackslashes = [
            "https:/\(password)\\x@collector.example/hook",
            "https:/\(password)\\\\@collector.example/hook",
            "http:/\(password)\\x@localhost/hook",
            "wss:/\(password)\\x@collector.example/hook",
            "postgres:/\(password)\\x@db/app",
            "https:/\(password)\\@localhost/hook",
            "https:/\(password)\\@db/hook",
            "https:/\(password)\\@[::1]/hook",
            "https:/\(password)\\@collector\u{3002}example/hook",
            "https:/\(password)\\@collector.example/hook",
        ]
        for value in schemeBackslashes {
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: [password], label: "scheme backslash command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: [password], label: "scheme backslash cwd")
        }
        let extenders = ["\u{FE0F}", "\u{FE0E}", "\u{034F}", "\u{200D}"]
        for mark in extenders {
            let glued = "https://\(password)@\(mark)collector.example/hook"
            let before = "https://\(mark)\(password)@collector.example/hook"
            for value in [glued, before] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": value]),
                    absent: [password], label: "at extender command")
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                    absent: [password], label: "at extender cwd")
            }
        }
        let named = "postgres://user:\(password)@\u{FE0F}db.example/app"
        let home = Fixture()
        try home.write(".cursor/mcp.json", try hostJSON("db", ["command": named, "args": ["--cwd=\(named)"]]))
        let review = Mutex("")
        let result = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: home.environment(presence: Self.present),
            show: { text in review.withLock { $0 += text } }
        ).get()
        let text = review.withLock { $0 }
        #expect(text.contains(password))
        #expect(result.contains("wrote mcp.json"))
        #expect(home.text(".config/rv/mcp.json").contains(named))
        #expect(home.keychain.items.withLock { $0 }.isEmpty)
    }

    @Test func importRefusesAnExtraSlashOrAnEmptyAtBeforeThePassword() async throws {
        let password = "supersecretpassword"
        let urls = [
            "https:///\(password)@collector.example/hook",
            "wss:///\(password)@collector.example/hook",
            "http:///\(password)@collector.example/hook",
            "https:////\(password)@collector.example/hook",
            "postgres:///\(password)@db/app",
            "https://\\/\(password)@collector.example/hook",
            "https:\\//\(password)@collector.example/hook",
            "https:/\\/\(password)@collector.example/hook",
            "https://\t/\(password)@collector.example/hook",
            "https://\n/\(password)@collector.example/hook",
            "https://\r/\(password)@collector.example/hook",
            "https://@\(password)@collector.example/hook",
            "https://@\(password)@localhost/hook",
            "https://@\(password)@db/hook",
            "https://@\(password)@[::1]/hook",
            "https://@\(password)@collector\u{3002}example/hook",
            "wss://@\(password)@collector.example/hook",
            "postgres://@\(password)@db/app",
        ]
        for value in urls {
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: [password], label: "extra user command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: [password], label: "extra user cwd")
            guard case .failure(let failure) = AuditForwardRun.destination(value) else {
                Issue.record("to accepted \(value)")
                continue
            }
            #expect(failure.message.contains(password) == false)
            if let url = URL(string: value) {
                #expect(MCPRemoteServer.endpointProblem(url) != nil)
                try await expectImportRefused(
                    try hostJSON("api", ["url": value]),
                    absent: [password], label: "extra user remote")
            }
        }
    }

    @Test func importRefusesAMarkInsideAToken() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-"]
        let separators = ["%7E", "~", "%3B", "%2C", "%3F", "%26", "%22", "%27", "%00", "%5C", "!", "%21"]
        for mark in separators {
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "separator")
        }
        let finishedTilde = head + "%" + String(repeating: "25", count: 31) + "7E" + tail
        try await expectSplitSecretRefused(finishedTilde, absent: absent, label: "finished tilde")
        try await expectSplitSecretRefused(
            "Bearer%20" + finishedTilde, absent: absent + ["Bearer%20"], label: "bearer tilde", headerOnly: true)
        try await expectSplitSecretRefused(
            "Basic%20" + finishedTilde, absent: absent + ["Basic%20"], label: "basic tilde", headerOnly: true)

        let extenders = ["%21", "%EF%BC%8E", "%CC%A3", "\u{FF0E}", "\u{0323}"]
        for mark in extenders {
            try await expectSplitSecretRefused(head + mark + tail, sk: "sk-12345678g" + mark + tail, absent: absent, label: "short mark")
            try await expectSplitSecretRefused(
                head + mark + extra, sk: "sk-12345678g" + mark + extra, absent: absent + [extra], label: "extra mark")
        }
        try await expectSplitSecretRefused(
            "sk-12345678g%21" + extra, absent: absent + [extra], label: "sk bang extra", headerOnly: true)

        let slashForms = [
            head + "%3A%2F%2F" + tail,
            head + "%3A%2F%2F" + extra,
            head + "://" + tail,
            head + "://" + extra,
            "x" + head + "%2F" + tail,
            "x" + head + "%2F" + extra,
            "." + head + "%2F" + tail,
        ]
        for value in slashForms {
            try await expectSplitSecretRefused(value, absent: absent + [extra], label: "slash form")
        }

        let controls = [
            "\u{0001}", "\u{0008}", "\u{000E}", "\u{001F}", "\u{007F}", "\u{0080}", "\u{009F}",
            "\u{0300}", "\u{E0100}", "\u{E01EF}",
            "%01", "%08", "%0E", "%1F", "%7F", "%C2%80", "%C2%9F", "%CC%80", "%F3%A0%84%80",
        ]
        for mark in controls {
            try await expectSplitSecretRefused(
                head + mark + extra, sk: "sk-12345678g" + mark + extra, absent: absent + [extra], label: "control")
        }
        let finishedControl = head + "%" + String(repeating: "25", count: 31) + "01" + tail
        try await expectSplitSecretRefused(finishedControl, absent: absent, label: "finished control")
        try await expectSplitSecretRefused(
            "Bearer%20" + finishedControl, absent: absent + ["Bearer%20"], label: "bearer control", headerOnly: true)
        try await expectSplitSecretRefused(
            "Basic%20" + finishedControl, absent: absent + ["Basic%20"], label: "basic control", headerOnly: true)
        let spaced = "ctx7sk-12345678 ghp_\(tail)"
        try await expectSplitSecretRefused(spaced, absent: ["ghp_", tail], label: "space still two")
    }

    private func expectSplitSecretRefused(
        _ value: String, sk: String? = nil, absent: [String], label: String, headerOnly: Bool = false
    ) async throws {
        let key = sk ?? value
        if headerOnly == false {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: absent, label: "\(label) env")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": [value]]),
                absent: absent, label: "\(label) argument")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--api-key", value]]),
                absent: absent, label: "\(label) api-key")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--api-key=\(value)"]]),
                absent: absent, label: "\(label) api-key equals")
        }
        let schemeIsLiteral = value.hasPrefix("Bearer") || value.hasPrefix("Basic")
        try await expectImportRefused(
            try hostJSON("api", [
                "url": "https://mcp.example/mcp",
                "headers": [
                    "Authorization": schemeIsLiteral ? value : "Bearer \(value)",
                    "Proxy-Authorization": schemeIsLiteral ? value : "Basic \(value)",
                    "X-API-Key": key,
                    "Cookie": value,
                ],
            ]),
            absent: absent, label: "\(label) header")
    }

    @Test func importRefusesADollarAHashAndACompatibilityTwin() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-"]
        func finished(_ byte: String) -> String {
            "%" + String(repeating: "25", count: 31) + byte
        }
        let dollars = [head + "$" + tail, head + "$" + extra, head + "%24" + tail, head + finished("24") + tail]
        for value in dollars {
            try await expectSplitSecretRefused(value, sk: value.replacingOccurrences(of: head, with: "sk-12345678g"), absent: absent + [extra], label: "dollar")
        }
        for scheme in ["Bearer%20", "Basic%20"] {
            try await expectSplitSecretRefused(
                scheme + head + "%24" + tail, absent: absent + [scheme], label: "scheme dollar", headerOnly: true)
            try await expectSplitSecretRefused(
                scheme + head + finished("24") + tail, absent: absent + [scheme], label: "scheme dollar chain", headerOnly: true)
        }
        let hashes = [head + "#" + tail, head + "%23" + tail, "x" + head + "#" + tail]
        for value in hashes {
            try await expectSplitSecretRefused(value, absent: absent, label: "hash")
        }
        let hashed = head + "#" + tail
        for scheme in ["Bearer%20", "Basic%20"] {
            for body in [hashed, head + "%23" + tail, head + finished("23") + tail] {
                try await expectSplitSecretRefused(
                    scheme + body, absent: absent + [scheme], label: "scheme hash")
            }
        }

        let question = "\u{037E}"
        let questionChain = head + finished("CD") + finished("BE") + tail
        for value in [head + question + tail, head + "%CD%BE" + tail, questionChain] {
            try await expectSplitSecretRefused(
                value, sk: "sk-12345678g" + String(value.dropFirst(head.count)), absent: absent, label: "greek question")
        }
        try await expectSplitSecretRefused(head + question + extra, absent: absent + [extra], label: "greek question extra")
        for scheme in ["Bearer%20", "Basic%20"] {
            try await expectSplitSecretRefused(
                scheme + head + "%CD%BE" + tail, absent: absent + [scheme], label: "scheme greek", headerOnly: true)
            try await expectSplitSecretRefused(
                scheme + questionChain, absent: absent + [scheme], label: "scheme greek chain", headerOnly: true)
        }
        for disguised in ["x" + head + question + tail, "." + head + question + tail, "x" + head + "%CD%BE" + tail, "." + head + "%CD%BE" + tail] {
            try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised greek")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(disguised)"]]),
                absent: absent, label: "disguised greek cwd")
        }

        let twins: [UInt32] = [
            0xFF0F, 0xFF01, 0xFE52, 0xFF5E, 0xFF03, 0xFF20, 0xFF5C, 0xFE69, 0xFF04,
            0x2024, 0x207A, 0x207C, 0x208A, 0x208C, 0xFB29, 0xFE10, 0xFE13, 0xFE14, 0xFE15, 0xFE16,
            0xFE50, 0xFE54, 0xFE55, 0xFE56, 0xFE57, 0xFE5F, 0xFE60, 0xFE62, 0xFE66, 0xFE68, 0xFE6B,
            0xFF02, 0xFF06, 0xFF07, 0xFF0B, 0xFF0C, 0xFF1A, 0xFF1B, 0xFF1D, 0xFF1F, 0xFF3C,
        ]
        for code in twins {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            let longer = head + mark + extra
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "twin")
            try await expectSplitSecretRefused(longer, sk: "sk-12345678g" + mark + extra, absent: absent + [extra], label: "twin extra")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised twin")
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(disguised)"]]),
                    absent: absent, label: "disguised twin cwd")
            }
        }
        for encoded in ["%EF%BC%8F", "%EF%BC%81", "%EF%B9%92", "%EF%BD%9E"] {
            try await expectSplitSecretRefused(head + encoded + tail, absent: absent, label: "encoded twin")
            try await expectSplitSecretRefused(head + encoded + extra, absent: absent + [extra], label: "encoded twin extra")
        }
    }

    @Test func importRefusesADecompositionThatContainsASeparator() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-"]
        func percent(_ text: String) -> String {
            text.utf8.map { String(format: "%%%02X", $0) }.joined()
        }
        func chain32(_ text: String) -> String {
            text.utf8.map { byte in "%" + String(repeating: "25", count: 31) + String(format: "%02X", byte) }.joined()
        }
        let marks: [UInt32] = [0x2025, 0x2026, 0x203C, 0x2047, 0x2048, 0x2049, 0x2A74, 0x2A75, 0x2A76, 0xFE19, 0xFE30, 0x2260]
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            let encoded = head + percent(mark) + tail
            let chain = head + chain32(mark) + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "decomposition")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "decomposition extra")
            try await expectSplitSecretRefused(encoded, absent: absent, label: "decomposition percent")
            try await expectSplitSecretRefused(chain, absent: absent, label: "decomposition chain")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "decomposition cwd")
            for scheme in ["Bearer%20", "Basic%20"] {
                try await expectSplitSecretRefused(
                    scheme + value, absent: absent + [scheme], label: "decomposition scheme", headerOnly: true)
                try await expectSplitSecretRefused(
                    scheme + chain, absent: absent + [scheme], label: "decomposition scheme chain", headerOnly: true)
            }
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised decomposition")
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(disguised)"]]),
                    absent: absent, label: "disguised decomposition cwd")
            }
        }
    }

    @Test func importRefusesAnAsciiMarkInsideAToken() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-"]
        func finished(_ count: Int) -> String {
            "%" + String(repeating: "25", count: count)
        }
        let marks = ["%", "(", ")", "*", "<", ">", "[", "]", "^", "`", "{", "}", "\u{FF05}", "\u{FE6A}"]
        for mark in marks {
            try await expectSplitSecretRefused(
                head + mark + tail, sk: "sk-12345678g" + mark + tail, absent: absent, label: "ascii mark")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "ascii mark extra")
        }
        let percentForms = [
            head + "%25" + tail,
            head + finished(31) + tail,
            head + finished(32) + tail,
            head + "%EF%BC%85" + tail,
            head + "%EF%B9%AA" + tail,
        ]
        for value in percentForms {
            try await expectSplitSecretRefused(value, absent: absent, label: "percent mark")
        }
        for scheme in ["Bearer%20", "Basic%20"] {
            for body in [head + "%" + tail, head + "%25" + tail, head + finished(31) + tail, head + finished(32) + tail] {
                try await expectSplitSecretRefused(
                    scheme + body, absent: absent + [scheme, "Bearer%20"], label: "scheme percent")
            }
        }
        for prefix in ["x", "."] {
            for body in [head + "%" + tail, head + "%25" + tail, head + finished(31) + tail] {
                let disguised = prefix + body
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised percent")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesAFractionSlashAndNonASCIIPunctuation() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-"]
        func percent(_ text: String) -> String {
            text.utf8.map { String(format: "%%%02X", $0) }.joined()
        }
        func chain32(_ text: String) -> String {
            text.utf8.map { byte in "%" + String(repeating: "25", count: 31) + String(format: "%02X", byte) }.joined()
        }
        let slashMarks: [UInt32] = [
            0x00BC, 0x00BD, 0x00BE, 0x215F, 0x2189,
            0x2150, 0x2151, 0x2152, 0x2153, 0x2154, 0x2155, 0x2156, 0x2157,
            0x2158, 0x2159, 0x215A, 0x215B, 0x215C, 0x215D, 0x215E,
            0x33A7, 0x33A8, 0x33AE, 0x33AF, 0x33C6, 0x33DE, 0x33DF,
        ]
        let punctuation: [UInt32] = [0x00B7, 0x00A1, 0x2019, 0xFF0D, 0xFE63, 0xFF3F, 0xFE33]
        for code in slashMarks + punctuation {
            let mark = String(Unicode.Scalar(code)!)
            try await expectSplitSecretRefused(
                head + mark + tail, sk: "sk-12345678g" + mark + tail, absent: absent, label: "slash or punctuation")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "slash extra")
        }
        for code in [UInt32(0x00BD), 0x33DE, 0x00B7, 0xFF0D] {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            let encoded = head + percent(mark) + tail
            let chain = head + chain32(mark) + tail
            try await expectSplitSecretRefused(encoded, absent: absent, label: "encoded slash")
            try await expectSplitSecretRefused(chain, absent: absent, label: "slash chain")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "slash cwd")
            for scheme in ["Bearer%20", "Basic%20"] {
                try await expectSplitSecretRefused(
                    scheme + value, absent: absent + [scheme], label: "scheme slash", headerOnly: true)
                try await expectSplitSecretRefused(
                    scheme + chain, absent: absent + [scheme], label: "scheme slash chain", headerOnly: true)
            }
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised slash")
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(disguised)"]]),
                    absent: absent, label: "disguised slash cwd")
            }
        }
    }

    @Test func importRefusesASolidusOperatorInsideAToken() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        func chain(_ passes: Int, _ text: String) -> String {
            let repeats = passes - 1
            return text.utf8.map { byte in
                "%" + String(repeating: "25", count: repeats) + String(format: "%02X", byte)
            }.joined()
        }
        let marks: [UInt32] = [
            0x2216, 0x29F5, 0x29F6, 0x29F7, 0x29F8, 0x29F9, 0x2AFD, 0x2AFB, 0x1F67C, 0x1F67D,
            0x2212, 0x22C5, 0x2219, 0x02D7, 0xE002F,
        ]
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "solidus")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "solidus extra")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "solidus command")
        }
        let setMinus = "\u{2216}"
        let value = head + setMinus + tail
        let chain31 = head + chain(31, setMinus) + tail
        let chain32 = head + chain(32, setMinus) + tail
        try await expectSplitSecretRefused(head + "%E2%88%96" + tail, absent: absent, label: "set minus percent")
        try await expectSplitSecretRefused(chain31, absent: absent, label: "set minus 31")
        try await expectSplitSecretRefused(chain32, absent: absent, label: "set minus 32")
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
            absent: absent, label: "set minus cwd")
        for scheme in ["Bearer%20", "Basic%20"] {
            try await expectSplitSecretRefused(
                scheme + value, absent: absent + [scheme], label: "scheme set minus", headerOnly: true)
            try await expectSplitSecretRefused(
                scheme + chain31, absent: absent + [scheme], label: "scheme set minus 31", headerOnly: true)
            try await expectSplitSecretRefused(
                scheme + chain32, absent: absent + [scheme], label: "scheme set minus 32", headerOnly: true)
        }
        for disguised in ["x" + value, "." + value] {
            try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised set minus")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(disguised)"]]),
                absent: absent, label: "disguised set minus cwd")
        }
        for overlapped in ["AKIA\u{2216}Iza12345678", "ASIA\u{2216}Iza12345678"] {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "akia overlap")
        }
    }

    @Test func importRefusesACircledSlashAndALanguageTag() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let marks: [UInt32] = [
            0x2298, 0x29B8, 0x233F, 0x2340, 0x2341, 0x2342, 0x2349, 0x244A,
            0x27C8, 0x27C9, 0x27CB, 0x27CD, 0x29C4, 0x29C5, 0x2F03,
            0xE0001, 0x115F, 0x1160, 0x3164, 0xFFA0,
            0x1BCA0, 0x1BCA1, 0x1BCA2, 0x1BCA3,
            0x1D173, 0x1D174, 0x1D175, 0x1D176, 0x1D177, 0x1D178, 0x1D179, 0x1D17A,
            0xE005C,
        ]
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "circled slash")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "circled slash extra")
        }
        for code in [UInt32(0x2298), 0x29B8, 0x2F03, 0xE0001] {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "circled command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "circled cwd")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised circled")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "circled trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "circled akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesABoxDrawingDiagonalAndAnOperatorGlyph() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        var marks: [UInt32] = [0x2571, 0x2572, 0x2573, 0x1FBBD, 0x1FBBE, 0x2213, 0x2217, 0x2218]
        marks.append(contentsOf: UInt32(0x1FBA0)...UInt32(0x1FBAD))
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "box diagonal")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "box diagonal extra")
        }
        for code in [UInt32(0x2571), 0x2572, 0x2573, 0x1FBA0, 0x1FBAD, 0x1FBBD, 0x1FBBE, 0x2213, 0x2217, 0x2218] {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "box diagonal command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "box diagonal cwd")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised box diagonal")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "box diagonal trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "box diagonal akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesABlockDiagonalAndTheNextOperator() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        var marks: [UInt32] = [0x1FBAE, 0x1FBBF, 0x292B, 0x292C, 0x2214, 0x22C6, 0x27CC]
        marks.append(contentsOf: UInt32(0x1FB3C)...UInt32(0x1FB67))
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "block diagonal")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "block diagonal extra")
        }
        for code in [UInt32(0x1FBAE), 0x1FBBF, 0x1FB3C, 0x1FB50, 0x1FB67, 0x292B, 0x292C, 0x2214, 0x22C6, 0x27CC] {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "block diagonal command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "block diagonal cwd")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised block diagonal")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "block diagonal trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "block diagonal akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesASaltireAndTheNextDiagonal() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        var marks: [UInt32] = [0x1FBC0, 0x2613, 0x26DD, 0x2B59, 0x292F, 0x2930, 0x22C7]
        marks.append(contentsOf: UInt32(0x1F7A8)...UInt32(0x1F7AE))
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "saltire")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "saltire extra")
        }
        for code in [UInt32(0x1FBC0), 0x2613, 0x26DD, 0x2B59, 0x1F7A8, 0x1F7AB, 0x1F7AE, 0x292F, 0x2930, 0x22C7] {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "saltire command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "saltire cwd")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised saltire")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "saltire trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "saltire akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesAFallingDiagonalInASquare() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let mark = "\u{26DE}"
        let value = head + mark + tail
        try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "falling diagonal")
        try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "falling diagonal extra")
        try await expectImportRefused(
            try hostJSON("db", ["command": value]),
            absent: absent, label: "falling diagonal command")
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
            absent: absent, label: "falling diagonal cwd")
        for disguised in ["x" + value, "." + value] {
            try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised falling diagonal")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                ]),
                absent: absent + ["Bearer"], label: "falling diagonal trace")
        }
        for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "falling diagonal akia")
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesACircledTimesAndTheNextOperator() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let marks: [UInt32] = [0x2295, 0x2296, 0x2297, 0x2299, 0x229A, 0x229B]
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "circled times")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "circled times extra")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "circled times command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "circled times cwd")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised circled times")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "circled times trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "circled times akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesACircledEqualsAndTheSquaredOperators() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let marks: [UInt32] = [0x229C, 0x229D, 0x229E, 0x229F, 0x22A0, 0x22A1]
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "circled equals")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "circled equals extra")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "circled equals command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "circled equals cwd")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised circled equals")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "circled equals trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "circled equals akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesARightTackThroughTheNegatedTurnstile() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let marks: [UInt32] = [
            0x22A2, 0x22A3, 0x22A4, 0x22A5, 0x22A6, 0x22A7, 0x22A8,
            0x22A9, 0x22AA, 0x22AB, 0x22AC, 0x22AD, 0x22AE, 0x22AF,
        ]
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "right tack")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "right tack extra")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "right tack command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "right tack cwd")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised right tack")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "right tack trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "right tack akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesAPrecedesUnderRelationThroughTheDiamond() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let marks = Array(UInt32(0x22B0)...UInt32(0x22C4))
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "relation")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "relation extra")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "relation command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "relation cwd")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised relation")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "relation trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "relation akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesABowtieThroughSucceedsButNotEquivalent() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let marks = Array(UInt32(0x22C8)...UInt32(0x22E9))
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "bowtie")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "bowtie extra")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "bowtie command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "bowtie cwd")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised bowtie")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "bowtie trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "bowtie akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesAVerticalEllipsisThroughTheWavyLine() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let marks = Array(UInt32(0x22EE)...UInt32(0x2307))
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "ellipsis")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "ellipsis extra")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "ellipsis command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "ellipsis cwd")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised ellipsis")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "ellipsis trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "ellipsis akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesABottomRightCropThroughTheKeyboard() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let marks = Array(UInt32(0x230C)...UInt32(0x2328))
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "crop")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "crop extra")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "crop command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "crop cwd")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised crop")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "crop trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "crop akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesAnEraseToTheLeftThroughTheCircleJot() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let marks = Array(UInt32(0x232B)...UInt32(0x233E))
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "erase")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "erase extra")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "erase command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "erase cwd")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised erase")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "erase trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "erase akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesAQuadLessThanThroughTheQuadRightwardsArrow() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let marks = Array(UInt32(0x2343)...UInt32(0x2348))
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "quad")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "quad extra")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "quad command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "quad cwd")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised quad")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "quad trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "quad akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesACircledDigitOneThroughTwenty() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let marks = Array(UInt32(0x2460)...UInt32(0x2473))
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "circled")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "circled extra")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "circled command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "circled cwd")
            let joined = "g" + mark + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": joined]),
                absent: ["ghp_", tail], label: "circled joined command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": [joined, "--api-key", joined]]),
                absent: ["ghp_", tail], label: "circled joined argument")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised circled")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "circled trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "circled akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesACircledLetterAThroughTheLightArc() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let marks = Array(UInt32(0x24B6)...UInt32(0x2570)) + [UInt32(0xFFE8)]
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "circled letter")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "circled letter extra")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "circled letter command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "circled letter cwd")
            let joined = "g" + mark + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": joined]),
                absent: ["ghp_", tail], label: "circled letter joined command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": [joined, "--api-key", joined]]),
                absent: ["ghp_", tail], label: "circled letter joined argument")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised circled letter")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "circled letter trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "circled letter akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesALightLeftThroughTheBallotBox() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let marks = Array(UInt32(0x2574)...UInt32(0x2612)) + [UInt32(0xFFED), UInt32(0xFFEE)]
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "box drawing")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "box drawing extra")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "box drawing command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "box drawing cwd")
            let joined = "g" + mark + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": joined]),
                absent: ["ghp_", tail], label: "box drawing joined command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": [joined, "--api-key", joined]]),
                absent: ["ghp_", tail], label: "box drawing joined argument")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised box drawing")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "box drawing trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "box drawing akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesAnUmbrellaWithRainDrops() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let mark = String(Unicode.Scalar(0x2614)!)
        let value = head + mark + tail
        try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "umbrella")
        try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "umbrella extra")
        try await expectImportRefused(
            try hostJSON("db", ["command": value]),
            absent: absent, label: "umbrella command")
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "args": [value, "--api-key", value, "--api-key=\(value)"]]),
            absent: absent, label: "umbrella argument")
        let joined = "g" + mark + tail
        try await expectImportRefused(
            try hostJSON("db", ["command": joined]),
            absent: ["ghp_", tail], label: "umbrella joined command")
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "args": [joined, "--api-key", joined]]),
            absent: ["ghp_", tail], label: "umbrella joined argument")
        try await expectSplitSecretRefused("x" + value, absent: absent, label: "umbrella leading x")
        try await expectImportRefused(
            try hostJSON("api", [
                "url": "https://mcp.example/mcp",
                "headers": ["X-Trace": "x" + value, "Authorization": "Bearer \(value)"],
            ]),
            absent: absent + ["Bearer"], label: "umbrella trace")
        try await expectSplitSecretRefused("." + value, absent: absent, label: "umbrella leading dot")
        for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "umbrella akia")
        }
    }

    @Test func importRefusesAHotBeverage() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let mark = String(Unicode.Scalar(0x2615)!)
        let value = head + mark + tail
        try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "beverage")
        try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "beverage extra")
        try await expectImportRefused(
            try hostJSON("db", ["command": value]),
            absent: absent, label: "beverage command")
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "args": [value, "--api-key", value, "--api-key=\(value)"]]),
            absent: absent, label: "beverage argument")
        let joined = "g" + mark + tail
        try await expectImportRefused(
            try hostJSON("db", ["command": joined]),
            absent: ["ghp_", tail], label: "beverage joined command")
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "args": [joined, "--api-key", joined]]),
            absent: ["ghp_", tail], label: "beverage joined argument")
        try await expectSplitSecretRefused("x" + value, absent: absent, label: "beverage leading x")
        try await expectImportRefused(
            try hostJSON("api", [
                "url": "https://mcp.example/mcp",
                "headers": ["X-Trace": "x" + value, "Authorization": "Bearer \(value)"],
            ]),
            absent: absent + ["Bearer"], label: "beverage trace")
        try await expectSplitSecretRefused("." + value, absent: absent, label: "beverage leading dot")
        for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "beverage akia")
        }
        let halves = ["abcdefghij1234", "qrstuvwxyzabcd"]
        for scheme in ["https", "http", "wss", "postgres"] {
            let spelling = "abcdefghij1234\(mark)\(scheme)://qrstuvwxyzabcd"
            try await expectImportRefused(
                try hostJSON("db", ["command": spelling]),
                absent: halves, label: "beverage scheme command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": [spelling]]),
                absent: halves, label: "beverage scheme argument")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(spelling)"]]),
                absent: halves, label: "beverage scheme cwd")
            let hidden = "1234\(mark)\(scheme)://\(tail)"
            try await expectImportRefused(
                try hostJSON("db", ["command": hidden]),
                absent: [tail], label: "beverage scheme tail command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": [hidden, "--api-key", hidden, "--api-key=\(hidden)"]]),
                absent: [tail], label: "beverage scheme tail argument")
        }
    }

    @Test func importRefusesAFormatPrependGluedToADigitBeforeAScheme() async throws {
        let tail = "hp_1234567890abcdefghij"
        let marks = [
            UInt32(0x0600), 0x0601, 0x0602, 0x0603, 0x0604, 0x0605,
            0x06DD, 0x070F, 0x0890, 0x0891, 0x08E2, 0x110BD, 0x110CD,
        ]
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            for scheme in ["https", "http", "wss", "postgres"] {
                for spelling in [
                    mark + "4\(scheme)://\(tail)",
                    "123\(mark)4\(scheme)://\(tail)",
                ] {
                    try await expectImportRefused(
                        try hostJSON("db", ["command": spelling]),
                        absent: [tail], label: "prepend digit command")
                    try await expectImportRefused(
                        try hostJSON("db", ["command": "db-mcp", "args": [spelling]]),
                        absent: [tail], label: "prepend digit argument")
                    try await expectImportRefused(
                        try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(spelling)"]]),
                        absent: [tail], label: "prepend digit cwd")
                    try await expectImportRefused(
                        try hostJSON("db", ["command": "db-mcp", "args": ["--api-key", spelling, "--api-key=\(spelling)"]]),
                        absent: [tail], label: "prepend digit api-key")
                }
                let after = "4\(mark)\(scheme)://\(tail)"
                try await expectImportRefused(
                    try hostJSON("db", ["command": after]),
                    absent: [tail], label: "prepend after digit")
            }
        }
    }

    @Test func importRefusesAHyphenOrUnderscoreBeforeAScheme() async throws {
        let tail = "hp_1234567890abcdefghij"
        for glue in ["-", "_"] {
            for scheme in ["https", "http", "wss", "postgres"] {
                let spelling = "1234\(glue)\(scheme)://\(tail)"
                try await expectImportRefused(
                    try hostJSON("db", ["command": spelling]),
                    absent: [tail], label: "glue scheme command")
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "args": [spelling]]),
                    absent: [tail], label: "glue scheme argument")
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "args": ["--api-key", spelling, "--api-key=\(spelling)"]]),
                    absent: [tail], label: "glue scheme api-key")
            }
        }
    }

    @Test func importRefusesADownTackUnderbarThroughTheOCRAccountNumber() async throws {
        let tail = "hp_1234567890abcdefghij"
        let extra = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-", "AKIA", "AIza", "ASIA"]
        let marks = Array(UInt32(0x234A)...UInt32(0x2426)) + Array(UInt32(0x2440)...UInt32(0x2449))
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = head + mark + tail
            try await expectSplitSecretRefused(value, sk: "sk-12345678g" + mark + tail, absent: absent, label: "ocr")
            try await expectSplitSecretRefused(head + mark + extra, absent: absent + [extra], label: "ocr extra")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "ocr command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "ocr cwd")
            let joined = "g" + mark + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": joined]),
                absent: ["ghp_", tail], label: "ocr joined command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": [joined, "--api-key", joined]]),
                absent: ["ghp_", tail], label: "ocr joined argument")
            for disguised in ["x" + value, "." + value] {
                try await expectSplitSecretRefused(disguised, absent: absent, label: "disguised ocr")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": ["X-Trace": disguised, "Authorization": "Bearer \(value)"],
                    ]),
                    absent: absent + ["Bearer"], label: "ocr trace")
            }
            for overlapped in ["AKIA" + mark + "Iza12345678", "ASIA" + mark + "Iza12345678"] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": overlapped, "LOG_LEVEL": overlapped]]),
                    absent: ["AKIA", "ASIA", "AIza", "Iza12345678"], label: "ocr akia")
            }
        }
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesAJoinedPrefixOnACommandOrArgument() async throws {
        let tail = "hp_1234567890abcdefghij"
        let absent = ["ghp_", tail, "12345678"]
        var marks = Array(UInt32(0x232B)...UInt32(0x233E)) + Array(UInt32(0x2343)...UInt32(0x2348))
        marks.append(contentsOf: [
            0x00A8, 0x00AF, 0x00B4, 0x00B8, 0x037A, 0x0384, 0x0385, 0x309B, 0x309C, 0xFFE3,
            0x2017, 0x203E, 0xFDFA, 0xFDFB,
            0xFE70, 0xFE72, 0xFE74, 0xFE76, 0xFE78, 0xFE7A, 0xFE7C, 0xFE7E,
            0x1FBD, 0x1FBF, 0x1FC0, 0x1FC1, 0x1FED, 0x1FEE, 0x1FFD, 0x1FFE,
            0x0085, 0xE0001, 0xFFF9, 0xFFFA, 0xFFFB,
        ])
        marks.append(contentsOf: UInt32(0x02D8)...UInt32(0x02DD))
        marks.append(contentsOf: UInt32(0xFC5E)...UInt32(0xFC63))
        marks.append(contentsOf: UInt32(0xFE49)...UInt32(0xFE4C))
        marks.append(contentsOf: UInt32(0x1FCD)...UInt32(0x1FCF))
        marks.append(contentsOf: UInt32(0x1FDD)...UInt32(0x1FDF))
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = "g" + mark + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: absent, label: "joined command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": [value]]),
                absent: absent, label: "joined argument")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: absent, label: "joined cwd")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--api-key", value]]),
                absent: absent, label: "joined api-key")
        }
        let contiguous = "x" + String(Unicode.Scalar(0x232B)!) + "ghp_12345678"
        try await expectImportRefused(
            try hostJSON("db", ["command": contiguous]),
            absent: absent, label: "contiguous command")
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "args": [contiguous]]),
            absent: absent, label: "contiguous argument")
        try await expectSplitSecretRefused("ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importWritesAUserPasswordURLThatCarriesAPort() async throws {
        let password = "supersecretpassword"
        let ports = [
            "postgres://user:\(password)@db.example:5432/app",
            "https://user:\(password)@collector.example:8080/hook",
            "https://user:\(password)@collector.example/hook1234",
        ]
        let plain = "postgres://user:\(password)@db.example/app"
        func expectWritten(_ fields: [String: Any], url: String) async throws {
            let home = Fixture()
            try home.write(".cursor/mcp.json", try hostJSON("db", fields))
            let review = Mutex("")
            let result = try await MCPRun.importServers(
                host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
                environment: home.environment(presence: Self.present),
                show: { text in review.withLock { $0 += text } }
            ).get()
            #expect(review.withLock { $0 }.contains(password), "\(url)")
            #expect(result.contains("wrote mcp.json"), "\(url)")
            #expect(home.text(".config/rv/mcp.json").contains(url), "\(url)")
            #expect(home.keychain.items.withLock { $0 }.isEmpty, "\(url)")
        }
        for url in ports + [plain] {
            try await expectWritten(["command": url], url: url)
            try await expectWritten(["command": "db-mcp", "args": ["--cwd=\(url)"]], url: url)
        }
        for url in ports {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["LOG_LEVEL": url]]),
                absent: [password, "5432", "8080", "hook1234"], label: "port env")
        }
        try await expectWritten(["command": "db-mcp", "env": ["LOG_LEVEL": plain]], url: plain)
        try await expectImportRefused(
            try hostJSON("db", ["command": "https://:\(password)@collector.example/hook"]),
            absent: [password], label: "password only")
        let joined = "g" + String(Unicode.Scalar(0x232B)!) + "hp_1234567890abcdefghij"
        try await expectImportRefused(
            try hostJSON("db", ["command": joined]),
            absent: ["ghp_", "hp_1234567890abcdefghij"], label: "joined command")
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "args": [joined]]),
            absent: ["ghp_", "hp_1234567890abcdefghij"], label: "joined argument")
    }

    @Test func importRefusesASchemeSplitOfANonPrefixToken() async throws {
        let spelling = "abcdefghij1234klmnop://qrstuvwxyzabcd"
        let absent = ["abcdefghij1234", "qrstuvwxyzabcd"]
        try await expectImportRefused(
            try hostJSON("db", ["command": spelling]),
            absent: absent, label: "scheme command")
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(spelling)"]]),
            absent: absent, label: "scheme cwd")
        let embedded = "g://hp_1234567890abcdefghij"
        try await expectImportRefused(
            try hostJSON("db", ["command": embedded]),
            absent: ["ghp_", "hp_1234567890abcdefghij"], label: "scheme prefix command")
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "args": [embedded]]),
            absent: ["ghp_", "hp_1234567890abcdefghij"], label: "scheme prefix argument")
    }

    @Test func importRefusesASchemeNameAfterDigits() async throws {
        let tails = ["https", "http", "wss", "postgres"]
        let absent = ["abcdefghij1234", "qrstuvwxyzabcd"]
        for tail in tails {
            let spelling = "abcdefghij1234\(tail)://qrstuvwxyzabcd"
            try await expectImportRefused(
                try hostJSON("db", ["command": spelling]),
                absent: absent, label: "embedded \(tail) command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(spelling)"]]),
                absent: absent, label: "embedded \(tail) cwd")
        }
    }

    @Test func importRefusesASchemeNameAfterADroppedSeparator() async throws {
        let schemes = ["https", "http", "wss", "postgres"]
        var marks = Array(UInt32(0x2574)...UInt32(0x2612)).map { String(Unicode.Scalar($0)!) }
        marks.append(contentsOf: [
            String(Unicode.Scalar(0xFFED)!),
            String(Unicode.Scalar(0xFFEE)!),
            String(Unicode.Scalar(0x2614)!),
            String(Unicode.Scalar(0x2615)!),
            String(Unicode.Scalar(0x00A8)!),
            ".",
        ])
        let halves = ["abcdefghij1234", "qrstuvwxyzabcd"]
        let tail = "hp_1234567890abcdefghij"
        for mark in marks {
            for scheme in schemes {
                let spelling = "abcdefghij1234\(mark)\(scheme)://qrstuvwxyzabcd"
                try await expectImportRefused(
                    try hostJSON("db", ["command": spelling]),
                    absent: halves, label: "separator scheme command")
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "args": [spelling]]),
                    absent: halves, label: "separator scheme argument")
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(spelling)"]]),
                    absent: halves, label: "separator scheme cwd")
                let hidden = "1234\(mark)\(scheme)://\(tail)"
                try await expectImportRefused(
                    try hostJSON("db", ["command": hidden]),
                    absent: [tail], label: "separator tail command")
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "args": [hidden]]),
                    absent: [tail], label: "separator tail argument")
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "args": ["--api-key", hidden]]),
                    absent: [tail], label: "separator tail api-key")
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "args": ["--api-key=\(hidden)"]]),
                    absent: [tail], label: "separator tail api-key equals")
            }
        }
    }

    @Test func importWritesAPortURLWithNoUserinfo() async throws {
        let urls = [
            "https://collector.example:8080/hook",
            "http://collector.example:8080/hook",
            "wss://collector.example:8080/hook",
            "postgres://db.example:5432/app",
            "https://collector.example/hook1234",
        ]
        for url in urls {
            for fields: [String: Any] in [
                ["command": url],
                ["command": "db-mcp", "args": ["--cwd=\(url)"]],
            ] {
                let home = Fixture()
                try home.write(".cursor/mcp.json", try hostJSON("db", fields))
                let review = Mutex("")
                let result = try await MCPRun.importServers(
                    host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
                    environment: home.environment(presence: Self.present),
                    show: { text in review.withLock { $0 += text } }
                ).get()
                #expect(result.contains("wrote mcp.json"), "\(url)")
                #expect(home.text(".config/rv/mcp.json").contains(url), "\(url)")
                #expect(home.keychain.items.withLock { $0 }.isEmpty, "\(url)")
            }
        }
    }

    @Test func importRefusesAPrependLetterGluedToAnAtSignOnAPort() async throws {
        let password = "supersecretpassword"
        let marks = [UInt32(0x0D4E), 0x111C2, 0x111C3, 0x1193F, 0x11941, 0x11A3A, 0x11D46, 0x11F02]
            + Array(UInt32(0x11A84)...UInt32(0x11A89))
        let tails = [
            "@db.example:5432/app",
            "@collector.example:8080/hook",
            "@collector.example/hook1234",
        ]
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            for tail in tails {
                let url = "postgres://user:\(password)" + mark + tail
                let https = "https://user:\(password)" + mark + tail
                let value = tail.hasPrefix("@db") ? url : https
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["LOG_LEVEL": value]]),
                    absent: [password], label: "prepend port env")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": [
                            "X-Trace": value,
                            "Authorization": value,
                            "X-API-Key": value,
                            "Cookie": value,
                        ],
                    ]),
                    absent: [password], label: "prepend port header")
            }
        }
    }

    @Test func importRefusesTuluTigalariRephaGluedToAnAtSignOnAPort() async throws {
        let password = "supersecretpassword"
        let mark = String(Unicode.Scalar(0x113D1)!)
        let tails = [
            ("postgres://user:\(password)" + mark + "@db.example:5432/app"),
            ("https://user:\(password)" + mark + "@collector.example:8080/hook"),
            ("https://user:\(password)" + mark + "@collector.example/hook1234"),
        ]
        for value in tails {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["LOG_LEVEL": value]]),
                absent: [password], label: "repha port env")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "X-Trace": value,
                        "Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                    ],
                ]),
                absent: [password], label: "repha port header")
        }
    }

    @Test func importRefusesAPrependScalarGluedToAnAtSign() async throws {
        let password = "supersecretpassword"
        let marks = [UInt32](0x0600...0x0605) + [0x06DD, 0x070F] + [UInt32](0x0890...0x0891)
            + [0x08E2, 0x110BD, 0x110CD, 0x0D4E] + [UInt32](0x111C2...0x111C3)
            + [0x1193F, 0x11941, 0x11A3A] + [UInt32](0x11A84...0x11A89) + [0x11D46, 0x11F02]
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let values = [
                "https://:\(password)\(mark)@collector.example/hook",
                "http://:\(password)\(mark)@collector.example/hook",
                "wss://:\(password)\(mark)@collector.example/hook",
                "postgres://:\(password)\(mark)@db.example/app",
                "https://mcp.example?next=https://:\(password)\(mark)@evil.example/hook",
            ]
            for value in values {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                    absent: [password], label: "prepend at env")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": [
                            "Authorization": value,
                            "X-API-Key": value,
                            "Cookie": value,
                            "X-Trace": value,
                        ],
                    ]),
                    absent: [password], label: "prepend at header")
            }
        }
        let encoded = "https://:\(password)%E0%B5%8E@collector.example/hook"
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": encoded, "LOG_LEVEL": encoded]]),
            absent: [password], label: "encoded prepend at")
    }

    @Test func importRefusesANestedSchemeSplitByALineBreak() async throws {
        let password = "supersecretpassword"
        let values = [
            "https://mcp.example?next=https:%0A\\\(password)%%0040evil.example/hook",
            "https://mcp.example?next=https:%0D\\\(password)%%0040evil.example/hook",
            "https://mcp.example?next=https:%0A\\\\\(password)%%0040evil.example",
            "https://mcp.example?next=https:%0A//\(password)%%0040evil.example/hook",
            "https://mcp.example?next=https:%%0009\\\(password)%%0040evil.example/hook",
            "https://mcp.example?next=https:%09\\\(password)%40evil.example/hook",
            "https://mcp.example?next=http:%0A\\\(password)%%0040evil.example/hook",
            "https://mcp.example?next=wss:%%000A\\\(password)%%0040evil.example/hook",
            "https://mcp.example?next=postgres:%%000D\\\(password)%%0040db/app",
            "https://mcp.example?@https:%0A\\\(password)%%0040evil.example/hook",
        ]
        for value in values {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: [password], label: "split scheme env")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                        "X-Trace": value,
                    ],
                ]),
                absent: [password], label: "split scheme header")
        }
    }

    @Test func importRefusesANestedSchemeSplitByCarriageReturnAndLineFeed() async throws {
        let password = "supersecretpassword"
        let values = [
            "https://mcp.example?next=https:%0D%0A\\\(password)%%0040evil.example/hook",
            "https://mcp.example?next=https:%0D%0A\\\\\(password)%%0040evil.example",
            "https://mcp.example?next=https:%0D%0A//\(password)%%0040evil.example/hook",
            "https://mcp.example?next=https:%%000D%%000A\\\(password)%%0040evil.example/hook",
            "https://mcp.example?next=https:%0D%0A%%002F%%002F\(password)%%0040evil.example/hook",
            "https://mcp.example?next=https:%0D%0A%%005C%%005C\(password)%%0040evil.example/hook",
            "https://mcp.example?next=http:%0D%0A\\\(password)%%0040evil.example/hook",
            "https://mcp.example?next=wss:%0D%0A\\\(password)%%0040evil.example/hook",
            "https://mcp.example?next=postgres:%0D%0A\\\(password)%%0040db/app",
            "https://mcp.example?@https:%0D%0A\\\(password)%%0040evil.example/hook",
        ]
        for value in values {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: [password], label: "crlf scheme env")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                        "X-Trace": value,
                    ],
                ]),
                absent: [password], label: "crlf scheme header")
        }
    }

    @Test func importRefusesACarriageReturnAndLineFeedBeforeAPasswordColon() async throws {
        let password = "supersecretpassword"
        let values = [
            "https://%0D%0A:\(password)@collector.example/hook",
            "http://%0D%0A:\(password)@collector.example/hook",
            "wss://%0D%0A:\(password)@collector.example/hook",
            "postgres://%0D%0A:\(password)@db.example/app",
            "https://\\%0D%0A:\(password)@collector.example/hook",
            "https://%%000D%%000A:\(password)@collector.example/hook",
        ]
        for value in values {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: [password], label: "crlf password env")
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: [password], label: "crlf password command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: [password], label: "crlf password cwd")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                        "X-Trace": value,
                    ],
                ]),
                absent: [password], label: "crlf password header")
        }
    }

    @Test func importRefusesANestedSchemeHiddenByABackslashOrAnEarlierAt() async throws {
        let password = "supersecretpassword"
        var values = [
            "https://mcp.example?@https://\(password)%%0040evil.example/hook",
            "https://mcp.example?next=https:\\\\\(password)%%0040evil.example",
        ]
        for scheme in ["https", "http", "wss", "postgres"] {
            values.append("https://mcp.example?next=\(scheme):\\\(password)%%0040evil.example/hook")
        }
        for value in values {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: [password], label: "hidden nested env")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                        "X-Trace": value,
                    ],
                ]),
                absent: [password], label: "hidden nested header")
        }
    }

    @Test func importRefusesASecondStrippedByteInsideAPercentEscape() async throws {
        let tail = "hp_1234567890abcdefghij"
        let absent = ["ghp_", "sk-", "ctx7sk", "AKIA", "ASIA", "AIza", "%67", "%73", "%00"]
        let deep = "%25%25%0000%25%25%000000"
        let values = [
            deep + "67" + tail,
            "%%00%%000067" + tail,
            "x" + deep + "67hp_12345678",
            "." + deep + "67" + tail,
            "Bearer%20" + deep + "67" + tail,
            deep + "73k-12345678",
            deep + "41KIA1234567890ABCD",
            deep + "41SIA1234567890ABCD",
            deep + "41IzaSyA1234567890abcd",
            "ctx7" + deep + "73k-12345678",
        ]
        for value in values {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: absent + [value], label: "second strip env")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": [value, "--cwd=\(value)", "--api-key=\(value)"]]),
                absent: absent + [value], label: "second strip argument")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                        "X-Trace": value,
                    ],
                ]),
                absent: absent + [value], label: "second strip header")
        }
    }

    @Test func importRefusesAStrippedByteThatRevealsPasswordUserinfo() async throws {
        let password = "supersecretpassword"
        let values = [
            "https://\(password)%%0040collector.example/hook",
            "wss://\(password)%%0040collector.example/hook",
            "http://\(password)%%0040localhost/hook",
            "postgres://\(password)%%0040db/app",
            "https://\(password)%%0040[::1]/hook",
            "https://\(password)%%0040collector\u{3002}example/hook",
            "https://\(password)%4%000collector.example/hook",
            "https://\(password)\u{FE0F}%%0040collector.example/hook",
            "https:%%002F%%002F%%002F\(password)@collector.example/hook",
            "https:%%005C%%005C\(password)@collector.example/hook",
            "https://%%0009/\(password)@collector.example/hook",
            "https://%%000A/\(password)@collector.example/hook",
            "https://%%000D/\(password)@collector.example/hook",
        ]
        for value in values {
            try await expectImportRefused(
                try hostJSON("db", ["command": value]),
                absent: [password], label: "revealed user command")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(value)"]]),
                absent: [password], label: "revealed user cwd")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: [password], label: "revealed user env")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                        "X-Trace": value,
                    ],
                ]),
                absent: [password], label: "revealed user header")
            guard case .failure(let failure) = AuditForwardRun.destination(value) else {
                Issue.record("to accepted \(value)")
                continue
            }
            #expect(failure.message.contains(password) == false)
            if let url = URL(string: value) {
                #expect(MCPRemoteServer.endpointProblem(url) != nil)
                try await expectImportRefused(
                    try hostJSON("api", ["url": value]),
                    absent: [password], label: "revealed user remote")
            }
        }
        let nested = "https://a.example/https://\(password)%%0040evil.example/hook"
        try await expectImportRefused(
            try hostJSON("db", ["command": nested]),
            absent: [password], label: "nested revealed command")
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "args": ["--cwd=\(nested)"]]),
            absent: [password], label: "nested revealed cwd")
        let visible = "https://user:\(password)@collector.example/hook"
        for value in [visible] {
            let home = Fixture()
            try home.write(".cursor/mcp.json", try hostJSON("db", ["command": value, "args": ["--cwd=\(value)"]]))
            let review = Mutex("")
            let result = try await MCPRun.importServers(
                host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
                environment: home.environment(presence: Self.present),
                show: { text in review.withLock { $0 += text } }
            ).get()
            let text = review.withLock { $0 }
            #expect(text.contains(password), "named user \(value)")
            #expect(result.contains("wrote mcp.json"))
            #expect(home.keychain.items.withLock { $0 }.isEmpty)
        }
    }

    @Test func importRefusesANestedRevealedPasswordAndARawSlashInTheUser() async throws {
        let password = "supersecretpassword"
        let nested = "https://a.example/https://\(password)%%0040evil.example/hook"
        let query = "https://mcp.example/hook?next=https://\(password)%%0040evil.example/hook"
        let slash = "https://supersecret%2Fpassword@collector.example/hook"
        for value in [nested, query, slash] {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: [password, "supersecret"], label: "nested or slash env")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                        "X-Trace": value,
                    ],
                ]),
                absent: [password, "supersecret"], label: "nested or slash header")
        }
        for value in [nested, query, slash] {
            guard case .failure(let failure) = AuditForwardRun.destination(value) else {
                Issue.record("to accepted \(value)")
                continue
            }
            #expect(failure.message.contains(password) == false)
            #expect(failure.message.contains("supersecret") == false)
            if let url = URL(string: value) {
                #expect(MCPRemoteServer.endpointProblem(url) != nil)
                try await expectImportRefused(
                    try hostJSON("api", ["url": value]),
                    absent: [password, "supersecret"], label: "nested or slash remote")
            }
        }
    }

    @Test func importRefusesAStripThatDoesNotFormAPercentEscape() async throws {
        let tail = "1234567890abcdefghij"
        let values = [
            "g\u{200B}h\u{FE0F}p\u{00AD}_\(tail)",
            "x\u{200B}ghp_12345678",
            "g\u{2060}h\u{034F}p\u{FEFF}_\(tail)",
            "x\u{180E}ghp_12345678",
        ]
        let absent = ["ghp_", tail, "12345678"]
        for value in values {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: absent, label: "strip join env")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                        "X-Trace": value,
                    ],
                ]),
                absent: absent, label: "strip join header")
        }
    }

    @Test func importRefusesAWhitespaceOrIgnorableThatJoinsOnePrefix() async throws {
        let tail = "hp_1234567890abcdefghij"
        let absent = ["ghp_", tail, "12345678"]
        var marks: [UInt32] = [
            0x0085, 0x1680, 0x205F, 0x3000,
            0xE0001, 0x115F, 0x1160, 0x3164, 0xFFA0,
            0xFFF9, 0xFFFA, 0xFFFB,
            0x1BCA0, 0x1BCA3, 0x1D173, 0x1D17A,
        ]
        marks.append(contentsOf: UInt32(0x2000)...UInt32(0x2006))
        marks.append(contentsOf: UInt32(0x2008)...UInt32(0x200A))
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = "g" + mark + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: absent, label: "joined prefix env")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                        "X-Trace": value,
                    ],
                ]),
                absent: absent, label: "joined prefix header")
        }
        for code in [UInt32(0x0085), 0x2008, 0xE0001, 0xFFF9, 0x1D17A] {
            let mark = String(Unicode.Scalar(code)!)
            for value in ["x" + mark + "ghp_12345678", "%67" + mark + tail] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                    absent: absent, label: "joined disguised env")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": [
                            "Authorization": value,
                            "X-API-Key": value,
                            "Cookie": value,
                            "X-Trace": value,
                        ],
                    ]),
                    absent: absent, label: "joined disguised header")
            }
        }
        try await expectSplitSecretRefused(
            "ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesASpacingMarkWhoseFoldContainsASpace() async throws {
        let tail = "hp_1234567890abcdefghij"
        let absent = ["ghp_", tail, "12345678"]
        var marks: [UInt32] = [
            0x00A8, 0x00AF, 0x00B4, 0x00B8, 0x037A, 0x0384, 0x0385, 0x309B, 0x309C, 0xFFE3,
            0xFE70, 0xFE72, 0xFE74, 0xFE76, 0xFE78, 0xFE7A, 0xFE7C, 0xFE7E,
        ]
        marks.append(contentsOf: UInt32(0x02D8)...UInt32(0x02DD))
        marks.append(contentsOf: UInt32(0xFC5E)...UInt32(0xFC63))
        for code in marks {
            let mark = String(Unicode.Scalar(code)!)
            let value = "g" + mark + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: absent, label: "spacing mark env")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                        "X-Trace": value,
                    ],
                ]),
                absent: absent, label: "spacing mark header")
        }
        for code in [UInt32(0x00A8), 0x02D8, 0xFC5E, 0xFFE3] {
            let mark = String(Unicode.Scalar(code)!)
            for value in ["x" + mark + "ghp_12345678", "%67" + mark + tail] {
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                    absent: absent, label: "spacing mark disguised env")
                try await expectImportRefused(
                    try hostJSON("api", [
                        "url": "https://mcp.example/mcp",
                        "headers": [
                            "Authorization": value,
                            "X-API-Key": value,
                            "Cookie": value,
                            "X-Trace": value,
                        ],
                    ]),
                    absent: absent, label: "spacing mark disguised header")
            }
        }
        try await expectSplitSecretRefused(
            "ctx7sk-12345678 ghp_\(tail)", absent: ["ghp_", tail], label: "space still two")
    }

    @Test func importRefusesAStrippedByteInsideAPercentEscape() async throws {
        let tail = "hp_1234567890abcdefghij"
        let absent = ["ghp_", "sk-", "ctx7sk", "AKIA", "ASIA", "AIza", "%67", "%73", "%00"]
        func nulChain(_ passes: Int) -> String {
            "%%" + String(repeating: "25", count: passes - 1) + "00" + "67" + tail
        }
        let values = [
            "%%0067" + tail,
            "%6%007" + tail,
            "%%0073k-12345678",
            "%%0041KIA1234567890ABCD",
            "%%0041SIA1234567890ABCD",
            "%%0041IzaSyA1234567890abcd",
            "ctx7%%0073k-12345678",
            "%%250067" + tail,
            "%%7f67" + tail,
            "%%7F67" + tail,
            "%%e2%80%8b67" + tail,
            "%%E2%80%8B67" + tail,
            nulChain(31),
            nulChain(32),
            "x%%0067hp_12345678",
            ".%%0067" + tail,
            "Bearer%20%%0067" + tail,
            "%%0063tx7sk-12345678",
        ]
        for value in values {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: absent + [value], label: "stripped env")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": [value, "--cwd=\(value)", "--api-key=\(value)"]]),
                absent: absent + [value], label: "stripped argument")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                        "X-Trace": value,
                    ],
                ]),
                absent: absent + [value], label: "stripped header")
        }
    }

    @Test func importRefusesAnEncodedTokenCopiedInTheClear() async throws {
        let absent = ["ghp_", "sk-", "ctx7sk", "AKIA", "ASIA", "AIza", "%67", "%73", "%63", "%41", "Bearer%20"]
        let values = [
            "%67hp_1234567890abcdefghij",
            "%73k-12345678",
            "%63tx7sk-12345678",
            "%41KIA1234567890ABCD",
            "%41SIA1234567890ABCD",
            "%41IzaSyA1234567890abcd",
            "x%67hp_12345678",
            "x%73k-12345678",
            ".%67hp_1234567890abcdefghij",
            ".%63tx7sk-12345678",
            "Bearer %67hp_1234567890abcdefghij",
            "Bearer%20%67hp_1234567890abcdefghij",
        ]
        for value in values {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: absent + [value], label: "encoded env")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                        "X-Trace": value,
                    ],
                ]),
                absent: absent + [value], label: "encoded header")
        }
        let bare = Fixture()
        let token = "sk-12345678"
        let other = "ctx7sk-12345678"
        try bare.write(".cursor/mcp.json", try hostJSON("db", [
            "command": "db-mcp",
            "env": ["LOG_LEVEL": token, "GITHUB_TOKEN": other],
            "args": [token, "--api-key", other],
        ]))
        let review = Mutex("")
        let result = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: bare.environment(presence: Self.present),
            show: { text in review.withLock { $0 += text } }
        ).get()
        let text = review.withLock { $0 }
        #expect(result.contains("wrote mcp.json"))
        #expect(text.contains("${secret:"))
        #expect(text.contains("→ secret"))
        #expect(bare.keychain.items.withLock { $0 }.isEmpty == false)
        let written = bare.text(".config/rv/mcp.json")
        #expect(written.contains("${secret:"))
        #expect(written.contains(token) == false)
        #expect(written.contains(other) == false)
    }

    @Test func importRefusesASplitterInsideAToken() async throws {
        let tail = "hp_1234567890abcdefghij"
        let head = "ctx7sk-12345678g"
        let absent = ["ctx7sk", "ghp_", tail, "sk-"]
        let marks = (0xFE00...0xFE0E).compactMap(Unicode.Scalar.init).map(String.init) + ["\u{2065}", "\u{000B}", "\u{000C}"]
        func percentEncoded(_ text: String) -> String {
            text.utf8.map { String(format: "%%%02X", $0) }.joined()
        }
        let encoded = (0xFE00...0xFE0E).compactMap(Unicode.Scalar.init).map { percentEncoded(String($0)) }
            + [percentEncoded("\u{2065}"), percentEncoded("\u{000B}"), percentEncoded("\u{000C}")]
        for mark in marks + encoded {
            let value = head + mark + tail
            let sk = "sk-12345678g" + mark + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: absent, label: "splitter env")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": "Bearer \(value)",
                        "Proxy-Authorization": "Basic \(value)",
                        "X-API-Key": sk,
                        "Cookie": value,
                    ],
                ]),
                absent: absent, label: "splitter header")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": [value, "--api-key", value]]),
                absent: absent, label: "splitter argument")
        }
        let longTail = tail + "EXTRA"
        for mark in ["\u{FE00}", "\u{2065}", "\u{000B}"] {
            let value = head + mark + longTail
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: absent + [longTail], label: "long splitter")
        }
        let spaced = "ctx7sk-12345678 ghp_\(tail)"
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": spaced, "LOG_LEVEL": spaced]]),
            absent: ["ghp_", tail], label: "space separates")

        let joiners = ["%2E", ".", "+", "=", ":", "%0A", "%E2%80%83", "\u{2003}"]
        for joiner in joiners {
            let value = head + joiner + tail
            let sk = "sk-12345678g" + joiner + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: absent, label: "joiner env")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": "Bearer \(value)",
                        "Proxy-Authorization": "Basic \(value)",
                        "X-API-Key": sk,
                        "Cookie": value,
                    ],
                ]),
                absent: absent, label: "joiner header")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": [value, "--api-key", value, "--api-key=\(value)"]]),
                absent: absent, label: "joiner argument")
        }
        let finished = "%" + String(repeating: "25", count: 31) + "2E" + tail
        let finishedValue = head + finished
        let spaceInside = [
            head + " " + tail,
            head + " " + longTail,
            " " + head + "%2E" + longTail,
            head + "%EF%B8%80" + longTail,
            "sk-12345678g%EF%B8%80" + longTail,
            head + "\u{FE00}" + longTail,
        ]
        for value in [finishedValue] + spaceInside {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: absent + [longTail], label: "space or finished decode")
        }
        let bearerChain = "Bearer%20" + finishedValue
        let variationChain = head
            + "%" + String(repeating: "25", count: 31) + "EF"
            + "%" + String(repeating: "25", count: 31) + "B8"
            + "%" + String(repeating: "25", count: 31) + "80"
            + longTail
        try await expectImportRefused(
            try hostJSON("api", [
                "url": "https://mcp.example/mcp",
                "headers": ["X-API-Key": "sk-12345678g%EF%B8%80" + longTail],
            ]),
            absent: absent + [longTail], label: "variation key")
        for value in [bearerChain, "Bearer " + finishedValue, variationChain, "Bearer%20" + variationChain] {
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": value,
                        "Proxy-Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                    ],
                ]),
                absent: absent + [longTail, "Bearer%20"], label: "bearer chain")
        }
    }

    @Test func importRefusesASplitTokenAnOverlapAndAStoppedDecode() async throws {
        let tail = "hp_1234567890abcdefghij"
        let longTail = tail + "EXTRA"
        let head = "ctx7sk-12345678g"
        let marks = [
            "\u{00AD}", "\u{206A}", "\u{206B}", "\u{206C}", "\u{206D}", "\u{206E}", "\u{206F}",
            "\u{FE0F}", "\u{180B}", "\u{180C}", "\u{180D}",
        ]
        let percents = ["%C2%AD", "%E2%81%AA", "%EF%B8%8F", "%E1%A0%8B"]
        let absent = ["ctx7sk", "ghp_", tail, "sk-"]
        for mark in marks + percents {
            let value = head + mark + tail
            let sk = "sk-12345678g" + mark + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: absent, label: "env mark")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": "Bearer \(value)",
                        "Proxy-Authorization": "Basic \(value)",
                        "X-API-Key": sk,
                        "Cookie": value,
                    ],
                ]),
                absent: absent, label: "header mark")
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "args": [value, "--api-key", value]]),
                absent: absent, label: "argument mark")
        }

        let separators = ["\t", "\u{2028}", "\u{2029}", "\u{202F}", "\u{2007}"]
        let disguised = [" ctx7sk-12345678g", "xctx7sk-12345678g", ".ctx7sk-12345678g", "ctx7sk-12345678://g"]
        for separator in separators {
            for prefix in disguised {
                let value = prefix + separator + longTail
                try await expectImportRefused(
                    try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                    absent: absent + [longTail], label: "split ghp_")
            }
            let joined = head + separator + tail
            let sk = "sk-12345678g" + separator + tail
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": joined, "LOG_LEVEL": joined]]),
                absent: absent, label: "short tail")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": "Bearer \(joined)",
                        "Proxy-Authorization": "Basic \(joined)",
                        "X-API-Key": sk,
                        "Cookie": joined,
                    ],
                ]),
                absent: absent, label: "short tail header")
        }

        let overlaps = ["AKIAIzaSyA12345678", "AKIASIA12345678", "ASIAKIA12345678"]
        for value in overlaps {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: [value], label: "overlap")
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": "Bearer \(value)",
                        "Proxy-Authorization": "Basic \(value)",
                        "X-API-Key": value,
                        "Cookie": value,
                    ],
                ]),
                absent: [value], label: "overlap header")
        }
        let later = "AKIAIzaSyA12345678^ghp_1234567890abcdefghij"
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": later, "LOG_LEVEL": later]]),
            absent: ["AKIAIzaSyA12345678", "ghp_", tail], label: "later prefix")
        let intact = "ctx7sk-12345678\u{206A}ghp_1234567890abcdefghij"
        try await expectImportRefused(
            try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": intact, "LOG_LEVEL": intact]]),
            absent: absent, label: "intact mark")

        let chain = "%" + String(repeating: "25", count: 32) + "67" + tail
        let stopped = [
            " " + chain,
            " ctx7sk-12345678^" + chain,
            "xctx7sk-12345678^" + chain,
            ".ctx7sk-12345678^" + chain,
            "ctx7sk-12345678://" + chain,
        ]
        for value in stopped {
            try await expectImportRefused(
                try hostJSON("db", ["command": "db-mcp", "env": ["GITHUB_TOKEN": value, "LOG_LEVEL": value]]),
                absent: absent + ["67hp_"], label: "stoppedEarly")
        }
        let bearer = "Bearer%20" + chain
        let bearerPrefixed = "Bearer%20ctx7sk-12345678^" + chain
        for value in [bearer, bearerPrefixed, chain] {
            try await expectImportRefused(
                try hostJSON("api", [
                    "url": "https://mcp.example/mcp",
                    "headers": [
                        "Authorization": value,
                        "Proxy-Authorization": value,
                        "X-API-Key": value,
                        "Cookie": value,
                    ],
                ]),
                absent: absent + ["67hp_", "Bearer%20"], label: "stoppedEarly header")
        }
    }

    @Test func importRefusesASchemeHiddenInAPath() async throws {
        let password = "supersecretpassword"
        let commands = [
            "https://mcp.example/sse/http://\(password)@collector.example",
            "https://mcp.example/sse/https://\(password)@collector.example",
            "https://mcp.example/sse/http:%5C%5C\(password)@collector.example",
            "wss://example.com/https://\(password)@collector.example",
        ]
        for command in commands {
            let home = Fixture()
            try home.write(".cursor/mcp.json", #"{"mcpServers":{"db":{"command":"\#(command)"}}}"#)
            let review = Mutex("")
            let result = try await MCPRun.importServers(
                host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
                environment: home.environment(presence: Self.present),
                show: { text in review.withLock { $0 += text } }
            ).get()
            let text = review.withLock { $0 } + result
            #expect(text.contains(password) == false, "\(command) \(text)")
            #expect(result.contains("nothing to import"), "\(command) \(text)")
            #expect(home.keychain.items.withLock { $0 }.isEmpty)
            #expect(FileManager.default.fileExists(atPath: home.config.appendingPathComponent("mcp.json").path) == false)
        }
        let remotes = [
            "https://a.example/http://\(password)@evil.example/hook",
            "https://a.example/https://\(password)@evil.example/hook",
        ]
        for url in remotes {
            let home = Fixture()
            try home.write(".cursor/mcp.json", #"{"mcpServers":{"api":{"url":"\#(url)"}}}"#)
            let review = Mutex("")
            let result = try await MCPRun.importServers(
                host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
                environment: home.environment(presence: Self.present),
                show: { text in review.withLock { $0 += text } }
            ).get()
            let text = review.withLock { $0 } + result
            #expect(text.contains(password) == false, "\(url) \(text)")
            #expect(result.contains("nothing to import"), "\(url) \(text)")
            #expect(home.keychain.items.withLock { $0 }.isEmpty)
        }
    }

    static let present = UserPresence { _, _ in .confirmed(method: "test") }
    static let absent = UserPresence { _, _ in .refused("this process has no terminal") }

    /// Answers the terminal challenge with whatever `typed` returns.
    static func typing(_ typed: @escaping @Sendable () -> String?) -> UserPresence {
        UserPresence { _, challenge in
            switch challenge {
            case .printedCode(let check):
                guard let code = typed(), check(code) else { return .refused("wrong confirmation code") }
                return .confirmed(method: "terminal confirmation code")
            case .echoCode:
                return .confirmed(method: "terminal confirmation")
            }
        }
    }

    private func signedConfiguration(_ fixture: Fixture, _ configuration: MCPConfiguration) throws {
        let signer = try #require(MCPApprovalKeyStore.file(configDirectory: fixture.config).loadOrCreate())
        _ = try configuration.write(configDirectory: fixture.config, signer: signer).get()
    }

    @Test func approveOnceGrantsAndAlwaysEditsTheAllowList() async throws {
        let fixture = Fixture()
        let environment = fixture.environment()
        try signedConfiguration(fixture, MCPConfiguration(servers: [
            MCPServerDefinition(name: "fs", command: "fs-mcp", tools: MCPToolPolicy(ask: ["write_file"]))
        ]))
        let store = environment.approvals
        let once = try #require(store.request(server: "fs", tool: "read_file", argumentsHash: "h1", argumentKeys: ["path"])?.id)
        let always = try #require(store.request(server: "fs", tool: "write_file", argumentsHash: "h2", argumentKeys: [])?.id)

        let pending = MCPRun.pendingText(MCPRun.pendingRows(store))
        #expect(pending.contains(once) && pending.contains("fs read_file") && pending.contains("path"))

        #expect(try await MCPRun.approve(id: once, always: false, environment: environment).get().contains("once"))
        #expect(store.consumeGrant(server: "fs", tool: "read_file", argumentsHash: "h1") == .granted(id: once))
        #expect(store.consumeGrant(server: "fs", tool: "read_file", argumentsHash: "h1") == .none)

        #expect(try await MCPRun.approve(id: always, always: true, environment: environment).get().contains("always"))
        let updated = try MCPRun.configuration(environment).get()
        let fs = try #require(updated.server(named: "fs"))
        #expect(fs.tools.allow == ["write_file"])
        #expect(fs.tools.ask.isEmpty)
        #expect(updated.decision(server: fs, tool: "write_file") == .allow)
        #expect(environment.integrity == .trusted)

        let missing = await MCPRun.approve(id: "missing", always: false, environment: environment)
        #expect(missing.failureMessage?.contains("no pending") == true)
        let events = fixture.approvalEvents()
        #expect(events.map(\.decision) == [.allowed, .allowed])
        #expect(events.first?.detail["method"] == "test")
        #expect(events.last?.detail["always"] == "true")
    }

    @Test func alwaysRefusesToolsWithArgumentRules() async throws {
        let fixture = Fixture()
        let environment = fixture.environment()
        let rule = try ToolArgumentRule.decode(.object([
            "tool": .string("query"), "when": .object(["/database": .object(["==": .string("prod")])]),
        ]))
        try signedConfiguration(fixture, MCPConfiguration(servers: [
            MCPServerDefinition(name: "db", command: "db-mcp", tools: MCPToolPolicy(rules: [.init(decision: .ask, rule: rule)]))
        ]))
        let id = try #require(environment.approvals.request(server: "db", tool: "query", argumentsHash: "h", argumentKeys: [])?.id)
        let always = await MCPRun.approve(id: id, always: true, environment: environment)
        #expect(always.failureMessage?.contains("has argument rules") == true)
        #expect(try MCPRun.configuration(environment).get().server(named: "db")?.tools.allow.isEmpty == true)
        #expect(MCPRun.trustReview(try MCPRun.configuration(environment).get()).contains(#"ask query when /database == "prod""#))
        var searching = try MCPRun.configuration(environment).get()
        searching.toolMode = .search
        #expect(MCPRun.trustReview(searching).contains("tool mode search: clients see only rv_search_tools and rv_call_tool"))

        var strict = MCPConfiguration(defaultDecision: .allow, servers: [
            MCPServerDefinition(
                name: "gh", command: "gh-mcp", tools: MCPToolPolicy(defaultDecision: .allow, allow: ["get_*"]),
                sandbox: MCPSandboxPolicy(network: false, hosts: ["api.github.com"])),
            MCPServerDefinition(name: "calc", command: "calc", sandbox: MCPSandboxPolicy(network: false)),
        ])
        strict.profile = .strict
        let review = MCPRun.trustReview(strict)
        #expect(review.hasPrefix("mcp.json: default deny for tools without a rule\n  profile strict: unlisted tools deny"), "\(review)")
        #expect(review.contains("allow get_* · other tools deny · network only to api.github.com"), "\(review)")
        #expect(review.contains(" · no network"), "\(review)")
    }

    @Test func trustReviewShowsHeaderValuesAndHidesPathTokens() throws {
        let remote = MCPRemoteServer(
            url: try #require(URL(string: "https://api.example.com/mcp")),
            headers: ["Authorization": "Bearer ${secret:GH_PAT}", "X-Team": "literal-value-9"], transport: .sse)
        let review = MCPRun.trustReview(MCPConfiguration(servers: [MCPServerDefinition(name: "gh", remote: remote)]))
        #expect(review.contains("  gh: https://api.example.com/mcp (remote, legacy SSE)"), "\(review)")
        #expect(review.contains("Authorization: Bearer ${secret:GH_PAT}"), "\(review)")
        #expect(review.contains("Authorization → secret GH_PAT"), "\(review)")
        #expect(review.contains("X-Team: literal-value-9"), "\(review)")
        #expect(review.contains("no sandbox") == false)

        let keyed = MCPRemoteServer(url: try #require(URL(string: "https://mcp.example.com/s/zk_8f3a9c2b7d1e4f60a5b3c9d2e7f1/mcp")))
        let hidden = MCPRun.trustReview(MCPConfiguration(servers: [MCPServerDefinition(name: "z", remote: keyed)]))
        #expect(hidden.contains("  z: https://mcp.example.com/… (credential-like part hidden) (remote, streamable HTTP)"), "\(hidden)")
        #expect(hidden.contains("zk_8f3a") == false)
    }

    @Test func approvingNeedsThePersonAndTheCodeTheGatewayPrinted() async throws {
        let fixture = Fixture()
        let probe = fixture.environment()
        let ticket = try #require(probe.approvals.request(server: "fs", tool: "write", argumentsHash: "h", argumentKeys: []))
        let code = try #require(ticket.code)

        let script = await MCPRun.approve(id: ticket.id, always: false, environment: fixture.environment(presence: Self.absent))
        #expect(script.failureMessage == "not approved: this process has no terminal")
        let guessed = await MCPRun.approve(
            id: ticket.id, always: false, environment: fixture.environment(presence: Self.typing { "AAAAA-AAAAA" }))
        #expect(guessed.failureMessage == "not approved: wrong confirmation code")
        #expect(probe.approvals.pending().map(\.id) == [ticket.id])
        #expect(probe.approvals.consumeGrant(server: "fs", tool: "write", argumentsHash: "h") == .none)

        let typed = await MCPRun.approve(
            id: ticket.id, always: false, environment: fixture.environment(presence: Self.typing { code.lowercased() }))
        #expect((try? typed.get())?.contains("once") == true)
        #expect(probe.approvals.consumeGrant(server: "fs", tool: "write", argumentsHash: "h") == .granted(id: ticket.id))

        let events = fixture.approvalEvents()
        #expect(events.map(\.decision) == [.denied, .denied, .allowed])
        #expect(events.first?.reason?.contains("no terminal") == true)
        #expect(events.last?.detail["method"] == "terminal confirmation code")
        #expect(events.allSatisfy { $0.subject == "fs/write" && $0.source == "rv mcp approve" })
    }

    @Test func outsideEditFailsCheckDowngradesAllowAndBlocksSigningUntilTrusted() async throws {
        let fixture = Fixture()
        try signedConfiguration(fixture, MCPConfiguration(servers: [
            MCPServerDefinition(name: "fs", command: "fs-mcp", tools: MCPToolPolicy(allow: ["read_*"], ask: ["write_*"]))
        ]))
        #expect(try report(fixture).passes)
        let path = ".config/rv/mcp.json"
        try fixture.write(path, fixture.text(path).replacingOccurrences(of: "write_*", with: "zz_*"))
        chmod(fixture.home.appendingPathComponent(path).path, 0o600)

        let environment = fixture.environment()
        let failing = try report(fixture)
        #expect(failing.passes == false)
        #expect(failing.integrity == "untrusted")
        #expect(MCPRun.checkText(failing, home: fixture.home).contains("mcp.json was edited outside rv"))
        #expect(MCPRun.listText(failing, home: fixture.home).contains("warning: mcp.json was edited outside rv"))
        let loaded = try MCPRun.configuration(environment).get()
        let fs = try #require(loaded.server(named: "fs"))
        #expect(loaded.decision(server: fs, tool: "read_file") == .ask)

        try fixture.write(".cursor/mcp.json", Self.cursorConfig)
        let importShown = Mutex("")
        let imported = await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false, environment: environment,
            show: { text in importShown.withLock { $0 += text } })
        #expect(imported.failureMessage?.contains("edited outside rv") == true)
        #expect(imported.failureMessage?.contains("nothing imported") == true)
        #expect(importShown.withLock { $0 }.isEmpty)
        #expect(fixture.keychain.items.withLock { $0 }.isEmpty)
        let id = try #require(environment.approvals.request(server: "fs", tool: "zz_x", argumentsHash: "h", argumentKeys: [])?.id)
        let always = await MCPRun.approve(id: id, always: true, environment: environment)
        #expect(always.failureMessage?.contains("edited outside rv") == true)

        let shown = Mutex("")
        let refused = await MCPRun.trust(environment: fixture.environment(presence: Self.absent), show: { text in
            shown.withLock { $0 += text }
        })
        #expect(refused.failureMessage == "not trusted: this process has no terminal")
        #expect(shown.withLock { $0 }.contains("fs: fs-mcp"))
        #expect(shown.withLock { $0 }.contains("ask zz_*"))
        #expect(environment.integrity.isTrusted == false)

        #expect(try await MCPRun.trust(environment: environment, show: { _ in }).get().contains("trusted mcp.json"))
        #expect(environment.integrity == .trusted)
        #expect(try await MCPRun.trust(environment: environment, show: { _ in }).get().contains("already matches"))
        let trusted = fixture.approvalEvents().last
        #expect(trusted?.source == "rv mcp trust")
        #expect(trusted?.detail["sha256"]?.count == 64)
    }

    @Test func trustNeedsAReadableConfiguration() async throws {
        let fixture = Fixture()
        let none = await MCPRun.trust(environment: fixture.environment(), show: { _ in })
        #expect(none.failureMessage == "there is no mcp.json to trust")
        try fixture.write(".config/rv/mcp.json", "{")
        chmod(fixture.home.appendingPathComponent(".config/rv/mcp.json").path, 0o600)
        chmod(fixture.config.path, 0o700)
        let invalid = await MCPRun.trust(environment: fixture.environment(), show: { _ in })
        #expect(invalid.failureMessage?.contains("not valid JSON") == true)
    }

    @Test func connectSignsInToARemoteServerAndForgetDeletesTheTokens() async throws {
        let fixture = Fixture()
        try fixture.write(".config/rv/mcp.json", #"""
            {"version": 1, "servers": [
              {"name": "linear", "url": "https://mcp.linear.app/mcp"},
              {"name": "gh", "url": "https://api.githubcopilot.com/mcp/", "headers": {"Authorization": "Bearer x"}},
              {"name": "local", "command": "fs-mcp"}
            ], "blocked": ["gone"]}
            """#)
        chmod(fixture.home.appendingPathComponent(".config/rv/mcp.json").path, 0o600)
        chmod(fixture.config.path, 0o700)
        let environment = fixture.environment()
        let resolver = SecretResolver { _ in .failure(.notFound("no secrets in this test")) }
        let flow = MCPOAuthFlow(
            http: { request in Self.oauthAnswers[request.url?.path ?? ""] },
            present: { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let value = { (name: String) in items.first { $0.name == name }?.value ?? "" }
                let redirect = URL(string: value("redirect_uri") + "?code=c0de&state=" + value("state"))!
                Thread.detachNewThread {
                    let done = DispatchSemaphore(value: 0)
                    URLSession(configuration: .ephemeral).dataTask(with: redirect) { _, _, _ in done.signal() }.resume()
                    _ = done.wait(timeout: .now() + 10)
                }
            }, timeout: 10)
        func connect(_ server: String, forget: Bool = false) -> Result<String, CommandFailure> {
            MCPRun.connect(
                server: server, clientID: nil, scope: nil, forget: forget, resolver: resolver, flow: flow, environment: environment)
        }

        #expect(connect("linear").failureMessage?.contains("edited outside rv") == true)
        _ = try await MCPRun.trust(environment: environment, show: { _ in }).get()
        #expect(connect("nope").failureMessage == "mcp.json has no server named nope")
        #expect(connect("local").failureMessage == "local runs a local command; only remote (url) servers sign in with OAuth")
        #expect(connect("gh").failureMessage?.contains("already sends an Authorization header") == true)

        let text = try connect("linear").get()
        #expect(text.contains("connected linear; tokens stored in "))
        #expect(text.contains("at-secret") == false && text.contains("rt-secret") == false)
        let stored = try #require(environment.oauthTokens.load("linear"))
        #expect(stored.accessToken == "at-secret" && stored.refreshToken == "rt-secret")
        #expect(stored.resource == "https://mcp.linear.app/mcp" && stored.clientID == "c-1")
        let connected = fixture.approvalEvents().last
        #expect(connected?.source == "rv mcp connect" && connected?.reason == "OAuth connected")
        #expect(connected?.detail["resource"] == "https://mcp.linear.app/mcp")
        let ledger = (try? String(contentsOf: fixture.config.appendingPathComponent("audit.jsonl"), encoding: .utf8)) ?? ""
        #expect(ledger.contains("at-secret") == false)

        #expect(try connect("linear", forget: true).get() == "deleted the OAuth tokens rv stored for linear\n")
        #expect(environment.oauthTokens.load("linear") == nil)
        #expect(fixture.approvalEvents().last?.reason == "OAuth tokens deleted")
    }

    private static let oauthAnswers: [String: MCPHTTPResponse] = [
        "/mcp": MCPHTTPResponse(
            status: 401,
            headers: ["WWW-Authenticate": #"Bearer resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource/mcp""#]),
        "/.well-known/oauth-protected-resource/mcp": MCPHTTPResponse(
            status: 200,
            body: Data(#"{"resource":"https://mcp.linear.app/mcp","authorization_servers":["https://auth.example"]}"#.utf8)),
        "/.well-known/oauth-authorization-server": MCPHTTPResponse(
            status: 200,
            body: Data(#"{"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token","registration_endpoint":"https://auth.example/register","code_challenge_methods_supported":["S256"]}"#.utf8)),
        "/register": MCPHTTPResponse(status: 201, body: Data(#"{"client_id":"c-1"}"#.utf8)),
        "/token": MCPHTTPResponse(
            status: 200,
            body: Data(#"{"access_token":"at-secret","token_type":"Bearer","expires_in":3600,"refresh_token":"rt-secret"}"#.utf8)),
    ]

    @Test func rvPathIsAbsoluteAndFoundOnPath() throws {
        #expect(MCPRun.rvExecutablePath(arguments: ["/usr/local/bin/rv"], environment: [:]) == "/usr/local/bin/rv")
        #expect(MCPRun.rvExecutablePath(arguments: ["sh"], environment: ["PATH": "/nope:/bin"]) == "/bin/sh")
        let relative = MCPRun.rvExecutablePath(arguments: ["./rv"], environment: [:])
        #expect(relative.hasPrefix("/") && relative.hasSuffix("/rv") && relative.contains("./") == false)
    }
}

private extension Result where Failure == CommandFailure {
    var failureMessage: String? {
        if case .failure(let failure) = self { return failure.message }
        return nil
    }
}
