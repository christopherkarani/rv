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
