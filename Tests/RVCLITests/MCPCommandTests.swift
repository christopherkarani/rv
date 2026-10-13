import Foundation
import RVDomain
import RVHistory
import RVIsolation
import RVMCP
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
                approvalKeys: .file(configDirectory: config), presence: presence)
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

    static let present = UserPresence { _, _ in .confirmed(method: "test") }
    static let absent = UserPresence { _, _ in .refused("this process has no terminal") }

    /// Answers the terminal challenge with whatever `typed` returns.
    static func typing(_ typed: @escaping @Sendable () -> String?) -> UserPresence {
        UserPresence { _, challenge in
            switch challenge {
            case .printedCode(let check):
                guard let code = typed(), check(code) else { return .refused("wrong confirmation code") }
                return .confirmed(method: "terminal confirmation code")
            case .deviceOwner:
                return .refused("a terminal is not device owner authentication")
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
        let imported = await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false, environment: environment)
        #expect(imported.failureMessage?.contains("edited outside rv") == true)
        #expect(imported.failureMessage?.contains("nothing imported") == true)
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

    @Test func trustRequiresDeviceOwnerAndBindsTheDigest() async throws {
        let fixture = Fixture()
        try signedConfiguration(fixture, MCPConfiguration(servers: [
            MCPServerDefinition(name: "fs", command: "fs-mcp")
        ]))
        let path = ".config/rv/mcp.json"
        try fixture.write(path, fixture.text(path).replacingOccurrences(of: "fs-mcp", with: "other-mcp"))
        chmod(fixture.home.appendingPathComponent(path).path, 0o600)
        let bytes = try Data(contentsOf: fixture.home.appendingPathComponent(path))
        let digest = RVDigest.sha256Hex([UInt8](bytes))

        let challenges = Mutex<[String]>([])
        let echoOnly = UserPresence { reason, challenge in
            challenges.withLock { $0.append(reason) }
            if case .deviceOwner = challenge {
                return .refused(UserPresence.deviceOwnerRefusal)
            }
            return .confirmed(method: "terminal confirmation")
        }
        let shown = Mutex("")
        let refused = await MCPRun.trust(environment: fixture.environment(presence: echoOnly), show: { text in
            shown.withLock { $0 += text }
        })
        #expect(refused.failureMessage == "not trusted: \(UserPresence.deviceOwnerRefusal)")
        #expect(shown.withLock { $0 }.contains("sha256 \(digest)"))
        #expect(challenges.withLock { $0 }.contains { $0.contains(digest) })
        #expect(fixture.environment().integrity.isTrusted == false)
        #expect(UserPresence.terminal("rv: trust", .deviceOwner) == .refused(UserPresence.deviceOwnerRefusal))
    }

    @Test func pseudoTerminalCannotCompletePrintedCode() {
        #expect(UserPresence.refusalForPrintedCode(ttyPath: nil) == .refused(UserPresence.noTerminalRefusal))
        #expect(UserPresence.refusalForPrintedCode(ttyPath: "") == .refused(UserPresence.noTerminalRefusal))
        for path in ["/dev/tty", "/dev/pts/4", "/dev/ttys000", "/dev/pty0"] {
            #expect(UserPresence.isCallerControlledTerminal(path))
            #expect(UserPresence.refusalForPrintedCode(ttyPath: path) == .refused(UserPresence.pseudoTerminalRefusal))
        }
        #expect(UserPresence.isCallerControlledTerminal("/dev/tty1") == false)
        #expect(UserPresence.isCallerControlledTerminal("/dev/console") == false)
        #expect(UserPresence.refusalForPrintedCode(ttyPath: "/dev/tty1") == nil)
    }

    @Test func approveDoesNotSignARowRewrittenDuringReview() async throws {
        let fixture = Fixture()
        try signedConfiguration(fixture, MCPConfiguration(servers: [
            MCPServerDefinition(name: "fs", command: "fs-mcp", tools: MCPToolPolicy(ask: ["write_file"]))
        ]))
        let environment = fixture.environment()
        let ticket = try #require(environment.approvals.request(
            server: "fs", tool: "write_file", argumentsHash: "h2", argumentKeys: ["path"]))
        let approvals = fixture.config.appendingPathComponent("mcp-approvals.json").path
        let seen = Mutex("")
        let swapping = UserPresence { reason, _ in
            seen.withLock { $0 = reason }
            let text = (try? String(contentsOfFile: approvals, encoding: .utf8)) ?? ""
            try? text.replacingOccurrences(of: "\"write_file\"", with: "\"steal\"")
                .replacingOccurrences(of: "\"h2\"", with: "\"evil\"")
                .write(toFile: approvals, atomically: true, encoding: .utf8)
            return .confirmed(method: "device owner authentication")
        }
        let refused = await MCPRun.approve(
            id: ticket.id, always: true, environment: fixture.environment(presence: swapping))
        let reason = seen.withLock { $0 }
        #expect(reason.contains("fs") && reason.contains("write_file") && reason.contains("h2"))
        #expect(refused.failureMessage == "the approval changed while you reviewed it; nothing was signed")
        let store = fixture.environment().approvals
        #expect(store.consumeGrant(server: "fs", tool: "steal", argumentsHash: "evil") == .none)
        #expect(store.consumeGrant(server: "fs", tool: "write_file", argumentsHash: "h2") == .none)
        #expect(store.pending().allSatisfy { $0.grantMAC == nil })
        let loaded = try MCPRun.configuration(fixture.environment()).get()
        let fs = try #require(loaded.server(named: "fs"))
        #expect(fs.tools.allow.isEmpty)
        #expect(fs.tools.ask == ["write_file"])
        #expect(loaded.decision(server: fs, tool: "write_file") == .ask)
    }

    @Test func importRequiresPresenceBeforeItSigns() async throws {
        let fixture = Fixture()
        try fixture.write(".cursor/mcp.json", Self.cursorConfig)
        let absent = await MCPRun.importServers(
            host: .cursor, names: ["seq"], project: nil, allowTools: true, dryRun: false,
            environment: fixture.environment(presence: Self.absent))
        #expect(absent.failureMessage?.contains("nothing imported") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("mcp.json").path) == false)

        let dry = try await MCPRun.importServers(
            host: .cursor, names: ["seq"], project: nil, allowTools: true, dryRun: true,
            environment: fixture.environment(presence: Self.absent)
        ).get()
        #expect(dry.contains("dry run"))
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("mcp.json").path) == false)

        let reasons = Mutex("")
        let watching = UserPresence { reason, challenge in
            if case .deviceOwner = challenge {
                reasons.withLock { $0 = reason }
                return .confirmed(method: "device owner authentication")
            }
            return .refused("not device owner")
        }
        let imported = try await MCPRun.importServers(
            host: .cursor, names: ["seq"], project: nil, allowTools: true, dryRun: false,
            environment: fixture.environment(presence: watching)
        ).get()
        #expect(imported.contains("wrote mcp.json"))
        #expect(reasons.withLock { $0 }.contains("seq:") && reasons.withLock { $0 }.contains("npx"))
        let loaded = try MCPRun.configuration(fixture.environment()).get()
        let seq = try #require(loaded.server(named: "seq"))
        #expect(seq.command == "npx")
        #expect(seq.tools.defaultDecision == .allow)
        #expect(fixture.environment().integrity == .trusted)
    }

    @Test func untrustedConfigurationDoesNotPlanLaunches() async throws {
        let fixture = Fixture()
        try signedConfiguration(fixture, MCPConfiguration(servers: [
            MCPServerDefinition(name: "fs", command: "fs-mcp", secrets: ["TOKEN": "GH"])
        ]))
        let path = ".config/rv/mcp.json"
        try fixture.write(path, fixture.text(path).replacingOccurrences(of: "fs-mcp", with: "evil-binary"))
        chmod(fixture.home.appendingPathComponent(path).path, 0o600)
        let calls = Mutex(0)
        let resolver = SecretResolver { _ in
            calls.withLock { $0 += 1 }
            guard let value = SecretValue("resolved-value") else {
                return .failure(.invalidValue("test secret"))
            }
            return .success(value)
        }
        let secrets = SecretsConfiguration(secrets: [
            SecretDefinition(name: "GH", source: .hostEnvironment(variable: "GH"), delivery: .environment)
        ])
        let environment = fixture.environment()
        let configuration = try MCPRun.configuration(environment).get()
        let refused = MCPRun.upstreamLaunches(
            names: ["fs"], configuration: configuration, environment: environment, secrets: secrets, resolver: resolver)
        #expect(refused.failureMessage?.contains("not launching MCP servers") == true)
        #expect(refused.failureMessage?.contains("edited outside rv") == true)
        #expect(calls.withLock { $0 } == 0)

        try signedConfiguration(fixture, MCPConfiguration(servers: [
            MCPServerDefinition(name: "fs", command: "fs-mcp", secrets: ["TOKEN": "GH"])
        ]))
        let trustedConfiguration = try MCPRun.configuration(fixture.environment()).get()
        let planned = try MCPRun.upstreamLaunches(
            names: ["fs"], configuration: trustedConfiguration, environment: fixture.environment(),
            secrets: secrets, resolver: resolver
        ).get()
        #expect(calls.withLock { $0 } == 1)
        #expect(planned.first?.1.arguments.first == "fs-mcp")
        #expect(planned.first?.1.arguments.contains("evil-binary") == false)
    }

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
