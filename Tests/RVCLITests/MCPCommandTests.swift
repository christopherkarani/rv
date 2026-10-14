#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
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
            keychain writer: SecretKeychainWriter? = nil, presence: UserPresence = MCPCommandTests.present,
            approvalKeys: MCPApprovalKeyStore? = nil
        ) -> MCPEnvironment {
            MCPEnvironment(
                configDirectory: config, home: home, processEnvironment: [:], keychain: writer ?? keychain.writer,
                approvalKeys: approvalKeys ?? .file(configDirectory: config), presence: presence)
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
        let onceTicket = try #require(store.request(server: "fs", tool: "read_file", argumentsHash: "h1", argumentKeys: ["path"]))
        let alwaysTicket = try #require(store.request(server: "fs", tool: "write_file", argumentsHash: "h2", argumentKeys: []))
        let once = onceTicket.id
        let always = alwaysTicket.id
        let onceCode = try #require(onceTicket.code)
        let alwaysCode = try #require(alwaysTicket.code)
        let codes = Mutex([onceCode, alwaysCode])
        let checking = fixture.environment(presence: Self.typing {
            codes.withLock { queue in
                guard queue.isEmpty == false else { return nil }
                return queue.removeFirst()
            }
        })

        let pending = MCPRun.pendingText(MCPRun.pendingRows(store))
        #expect(pending.contains(once) && pending.contains("fs read_file") && pending.contains("path"))

        #expect(try await MCPRun.approve(id: once, always: false, environment: checking).get().contains("once"))
        #expect(store.consumeGrant(
            server: "fs", tool: "read_file", argumentsHash: "h1", argumentKeys: ["path"]) == .granted(id: once))
        #expect(store.consumeGrant(
            server: "fs", tool: "read_file", argumentsHash: "h1", argumentKeys: ["path"]) == .none)

        #expect(try await MCPRun.approve(id: always, always: true, environment: checking).get().contains("always"))
        let updated = try MCPRun.configuration(environment).get()
        let fs = try #require(updated.server(named: "fs"))
        #expect(fs.tools.allow == ["write_file"])
        #expect(fs.tools.ask.isEmpty)
        #expect(updated.decision(server: fs, tool: "write_file") == .allow)
        #expect(environment.integrity == .trusted)

        let missing = await MCPRun.approve(id: "missing", always: false, environment: checking)
        #expect(missing.failureMessage?.contains("no pending") == true)
        let events = fixture.approvalEvents()
        #expect(events.map(\.decision) == [.allowed, .allowed])
        #expect(events.first?.detail["method"] == "terminal confirmation code")
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
        #expect(probe.approvals.consumeGrant(
            server: "fs", tool: "write", argumentsHash: "h", argumentKeys: []) == .none)

        let typed = await MCPRun.approve(
            id: ticket.id, always: false, environment: fixture.environment(presence: Self.typing { code.lowercased() }))
        #expect((try? typed.get())?.contains("once") == true)
        #expect(probe.approvals.consumeGrant(
            server: "fs", tool: "write", argumentsHash: "h", argumentKeys: []) == .granted(id: ticket.id))

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

    @Test func approveFromATerminalNameReachesDeviceOwner() {
        let touchID = PresenceOutcome.confirmed(method: "device owner authentication")
        let reached = UserPresence.finishPrintedCode(
            ttyPath: "/dev/ttys000", codeVerified: true, deviceOwner: touchID, deviceOwnerCanRun: true)
        #expect(reached == touchID)
        let skipped = UserPresence.finishPrintedCode(
            ttyPath: "/dev/ttys000", codeVerified: true, deviceOwner: nil, deviceOwnerCanRun: true)
        #expect(skipped == .refused(UserPresence.pseudoTerminalRefusal))
        let cancelled = UserPresence.finishPrintedCode(
            ttyPath: "/dev/ttys000", codeVerified: true,
            deviceOwner: .refused("authentication was cancelled or failed"), deviceOwnerCanRun: true)
        #expect(cancelled == .refused("authentication was cancelled or failed"))
        let codeFirst = UserPresence.finishPrintedCode(
            ttyPath: "/dev/ttys000", codeVerified: false, deviceOwner: touchID, deviceOwnerCanRun: true)
        #expect(codeFirst == .refused("wrong confirmation code"))
        let linux = UserPresence.finishPrintedCode(
            ttyPath: "/dev/pts/4", codeVerified: true, deviceOwner: nil, deviceOwnerCanRun: false)
        #expect(linux == .confirmed(method: "terminal confirmation code"))
        let console = UserPresence.finishPrintedCode(
            ttyPath: "/dev/tty1", codeVerified: true, deviceOwner: nil, deviceOwnerCanRun: true)
        #expect(console == .confirmed(method: "terminal confirmation code"))
    }

    @Test func pendingEscapesADecoyApprovalID() throws {
        let fixture = Fixture()
        let store = fixture.environment().approvals
        let decoy = try #require(store.request(server: "notes", tool: "echo", argumentsHash: "h-decoy", argumentKeys: []))
        let real = try #require(store.request(
            server: "fs", tool: "read_ssh", argumentsHash: "h-real", argumentKeys: ["path"]))
        let file = fixture.config.appendingPathComponent("mcp-approvals.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        let forged = "x\\u001b[2J\\u000d\\u0008\\u000b  \(real.id)  notes echo  no arguments"
        try text.replacingOccurrences(of: "\"\(decoy.id)\"", with: "\"\(forged)\"")
            .write(to: file, atomically: true, encoding: .utf8)
        let pending = MCPRun.pendingText(MCPRun.pendingRows(store))
        let scalars = Set(pending.unicodeScalars.map(\.value))
        #expect(scalars.contains(0x1B) == false)
        #expect(scalars.contains(0x0B) == false)
        #expect(scalars.contains(0x0D) == false)
        #expect(scalars.contains(0x08) == false)
        #expect(pending.contains("\\u001b"))
        #expect(pending.contains("\\u000b"))
        #expect(pending.contains(real.id))
        let lines = pending.split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines.contains { $0.hasPrefix(real.id) && $0.contains("notes echo") } == false)
        #expect(MCPRun.deniedLine(server: "fs", tool: "read\u{000B}ssh")
            .unicodeScalars.contains { $0.value == 0x0B } == false)
    }

    @Test func toolNameCSIDoesNotRedrawTheApproveReason() async throws {
        let fixture = Fixture()
        let trailer = "sha256 " + String(repeating: "0", count: 64)
        let tool = "write\u{009B}2J\u{009B}H\(trailer)"
        let store = fixture.environment().approvals
        let ticket = try #require(store.request(
            server: "fs", tool: tool, argumentsHash: "h1", argumentKeys: ["path"]))
        let code = try #require(ticket.code)
        let pending = MCPRun.pendingText(MCPRun.pendingRows(store))
        let reason = Mutex("")
        let presence = UserPresence { why, challenge in
            reason.withLock { $0 = why }
            guard case .printedCode(let check) = challenge, check(code) else {
                return .refused("wrong confirmation code")
            }
            return .confirmed(method: "terminal confirmation code")
        }
        _ = try await MCPRun.approve(
            id: ticket.id, always: false, environment: fixture.environment(presence: presence)).get()
        for text in [pending, reason.withLock { $0 }] {
            #expect(text.unicodeScalars.contains { $0.value == 0x9B } == false)
            #expect(text.contains("\\u009b"))
            #expect(text.split(whereSeparator: \.isNewline).map(String.init).contains(trailer) == false)
        }
    }

    @Test func quotedArgumentKeysDoNotCollapseAComma() async throws {
        let fixture = Fixture()
        let store = fixture.environment().approvals
        let two = try #require(store.request(
            server: "fs", tool: "write_file", argumentsHash: "h-two", argumentKeys: ["path", "contents"]))
        let one = try #require(store.request(
            server: "fs", tool: "write_file", argumentsHash: "h-one", argumentKeys: ["path, contents"]))
        let twoCode = try #require(two.code)
        let pending = MCPRun.pendingText(MCPRun.pendingRows(store))
        let lines = pending.split(whereSeparator: \.isNewline).map(String.init)
        let twoLine = try #require(lines.first { $0.contains(two.id) })
        let oneLine = try #require(lines.first { $0.contains(one.id) })
        #expect(twoLine.contains("\"path\", \"contents\""))
        #expect(oneLine.contains("\"path, contents\""))
        #expect(twoLine != oneLine)
        let reasons = Mutex<[String]>([])
        let presence = UserPresence { why, challenge in
            reasons.withLock { $0.append(why) }
            guard case .printedCode(let check) = challenge, check(twoCode) else {
                return .refused("wrong confirmation code")
            }
            return .confirmed(method: "terminal confirmation code")
        }
        _ = try await MCPRun.approve(
            id: two.id, always: false, environment: fixture.environment(presence: presence)).get()
        let shown = reasons.withLock { $0 }.joined(separator: "\n")
        #expect(shown.contains("\"path\", \"contents\""))
        #expect(shown.contains("\"path, contents\"") == false)
        #expect(store.consumeGrant(
            server: "fs", tool: "write_file", argumentsHash: "h-two", argumentKeys: ["path", "contents"])
            == .granted(id: two.id))
        #expect(store.consumeGrant(
            server: "fs", tool: "write_file", argumentsHash: "h-two", argumentKeys: ["path, contents"]) == .none)
        #expect(store.consumeGrant(
            server: "fs", tool: "write_file", argumentsHash: "h-one", argumentKeys: ["path, contents"]) == .none)
        #expect(store.pending().map(\.id) == [one.id])
        #expect(store.grant(
            id: one.id, server: "fs", tool: "write_file", argumentsHash: "h-one", argumentKeys: ["path", "contents"]) == nil)
    }

    @Test func symlinkScratchIsNotAReviewedWrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-scratch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("project")
        let scratch = root.appendingPathComponent("scratch")
        let home = root.appendingPathComponent("home")
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        #expect(symlink(target.path, scratch.path) == 0)
        let result = MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false, writable: []),
            scratch: scratch.path, home: home.path, configDirectory: root.appendingPathComponent("config").path,
            temporaryDirectory: tmp.path)
        guard case .failure(let error) = result else {
            Issue.record("a symlink scratch was allowed")
            return
        }
        #expect(error.message.contains("not the path reviewed"))
        #expect(error.message.contains("(subpath") == false)
        #expect(error.message.contains(canonicalPath(target.path)))
    }

    @Test func writableSymlinkPlantedAfterConfirmIsRefused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-writable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("notes")
        let target = root.appendingPathComponent("home")
        let scratch = root.appendingPathComponent("scratch")
        let home = root.appendingPathComponent("person")
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let server = MCPServerDefinition(
            name: "notes", command: "/bin/true",
            sandbox: MCPSandboxPolicy(network: false, writable: [link.path]))
        let review = MCPRun.trustReview(MCPConfiguration(servers: [server]))
        #expect(review.contains(link.path))
        #expect(review.contains(target.path) == false)
        #expect(symlink(target.path, link.path) == 0)
        let result = MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false, writable: [link.path]),
            scratch: scratch.path, home: home.path, configDirectory: root.appendingPathComponent("config").path,
            temporaryDirectory: tmp.path)
        guard case .failure(let error) = result else {
            Issue.record("a writable symlink planted after confirm was allowed")
            return
        }
        #expect(error.message.contains("not the path reviewed"))
        #expect(error.message.contains("(subpath") == false)
        #expect(error.message.contains(canonicalPath(target.path)))
    }

    private func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @Test func approveDoesNotSignARowRewrittenDuringReview() async throws {
        let fixture = Fixture()
        try signedConfiguration(fixture, MCPConfiguration(servers: [
            MCPServerDefinition(name: "fs", command: "fs-mcp", tools: MCPToolPolicy(ask: ["write_file"]))
        ]))
        let environment = fixture.environment()
        let ticket = try #require(environment.approvals.request(
            server: "fs", tool: "write_file", argumentsHash: "h2", argumentKeys: ["path"]))
        let code = try #require(ticket.code)
        let approvals = fixture.config.appendingPathComponent("mcp-approvals.json").path
        let seen = Mutex("")
        let swapping = UserPresence { reason, challenge in
            seen.withLock { $0 = reason }
            if case .printedCode(let check) = challenge {
                _ = check(code)
            }
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
        #expect(store.consumeGrant(
            server: "fs", tool: "steal", argumentsHash: "evil", argumentKeys: ["path"]) == .none)
        #expect(store.consumeGrant(
            server: "fs", tool: "write_file", argumentsHash: "h2", argumentKeys: ["path"]) == .none)
        #expect(store.pending().allSatisfy { $0.grantMAC == nil })
        let loaded = try MCPRun.configuration(fixture.environment()).get()
        let fs = try #require(loaded.server(named: "fs"))
        #expect(fs.tools.allow.isEmpty)
        #expect(fs.tools.ask == ["write_file"])
        #expect(loaded.decision(server: fs, tool: "write_file") == .ask)
    }

    @Test func approveDoesNotSignArgumentKeysRewrittenDuringReview() async throws {
        let fixture = Fixture()
        let environment = fixture.environment()
        let ticket = try #require(environment.approvals.request(
            server: "fs", tool: "write_file", argumentsHash: "h1", argumentKeys: ["path", "contents"]))
        let code = try #require(ticket.code)
        let approvals = fixture.config.appendingPathComponent("mcp-approvals.json").path
        let needle = "\"path\",\n        \"contents\""
        let swapping = UserPresence { _, challenge in
            if case .printedCode(let check) = challenge {
                _ = check(code)
            }
            let text = (try? String(contentsOfFile: approvals, encoding: .utf8)) ?? ""
            try? text.replacingOccurrences(of: needle, with: "\"note\"")
                .write(toFile: approvals, atomically: true, encoding: .utf8)
            return .confirmed(method: "device owner authentication")
        }
        let refused = await MCPRun.approve(
            id: ticket.id, always: false, environment: fixture.environment(presence: swapping))
        #expect(refused.failureMessage == "the approval changed while you reviewed it; nothing was signed")
        let store = fixture.environment().approvals
        let pending = MCPRun.pendingText(MCPRun.pendingRows(store))
        #expect(pending.contains("arguments changed outside rv"))
        #expect(pending.contains("arguments note") == false)
        #expect(pending.contains("path") == false)
        #expect(pending.contains("contents") == false)
        #expect(store.pending().map(\.argumentKeys) == [["note"]])
        #expect(store.pending().allSatisfy { $0.argumentsHash == "h1" && $0.grantMAC == nil })
        #expect(store.verifyCode(id: ticket.id, typed: code) == false)
        #expect(store.grant(
            id: ticket.id, server: "fs", tool: "write_file", argumentsHash: "h1", argumentKeys: ["path", "contents"]) == nil)
        #expect(store.consumeGrant(
            server: "fs", tool: "write_file", argumentsHash: "h1", argumentKeys: ["path", "contents"]) == .none)
    }

    @Test func touchIDWithoutThePrintedCodeDoesNotGrant() async throws {
        let fixture = Fixture()
        let store = fixture.environment().approvals
        let ticket = try #require(store.request(
            server: "fs", tool: "write_file", argumentsHash: "h1", argumentKeys: ["path", "contents"]))
        let touchID = UserPresence { _, _ in .confirmed(method: "device owner authentication") }
        let refused = await MCPRun.approve(
            id: ticket.id, always: false, environment: fixture.environment(presence: touchID))
        #expect(refused.failureMessage == "not approved: confirmation code was not checked")
        #expect(store.consumeGrant(
            server: "fs", tool: "write_file", argumentsHash: "h1", argumentKeys: ["path", "contents"]) == .none)
        #expect(store.pending().allSatisfy { $0.grantMAC == nil })
    }

    @Test func approveAfterRewrittenArgumentKeysDoesNotRunTheOriginalCall() async throws {
        let fixture = Fixture()
        let store = fixture.environment().approvals
        let ticket = try #require(store.request(
            server: "fs", tool: "write_file", argumentsHash: "h1", argumentKeys: ["path", "contents"]))
        let approvals = fixture.config.appendingPathComponent("mcp-approvals.json").path
        let needle = "\"path\",\n        \"contents\""
        let text = try String(contentsOfFile: approvals, encoding: .utf8)
        #expect(text.contains(needle))
        try text.replacingOccurrences(of: needle, with: "\"note\"")
            .write(toFile: approvals, atomically: true, encoding: .utf8)

        let pending = MCPRun.pendingText(MCPRun.pendingRows(store))
        #expect(pending.contains("arguments changed outside rv"))
        #expect(pending.contains("arguments note") == false)
        let touchID = UserPresence { _, _ in .confirmed(method: "device owner authentication") }
        let refused = await MCPRun.approve(
            id: ticket.id, always: false, environment: fixture.environment(presence: touchID))
        #expect(refused.failureMessage == "the approval changed while you reviewed it; nothing was signed")
        #expect(store.grant(
            id: ticket.id, server: "fs", tool: "write_file", argumentsHash: "h1", argumentKeys: ["note"]) == nil)
        #expect(store.consumeGrant(
            server: "fs", tool: "write_file", argumentsHash: "h1", argumentKeys: ["path", "contents"]) == .none)
    }

    @Test func pendingAndApproveEscapeAToolNameLineBreak() async throws {
        let fixture = Fixture()
        let trailer = "sha256 " + String(repeating: "0", count: 64)
        let tool = "write\u{000B}\(trailer)"
        let store = fixture.environment().approvals
        let ticket = try #require(store.request(
            server: "fs", tool: tool, argumentsHash: "h1", argumentKeys: ["path\n\(trailer)", "note\u{0008}x"]))
        let code = try #require(ticket.code)
        let pending = MCPRun.pendingText(MCPRun.pendingRows(store))
        #expect(pending.contains("\\u000b"))
        #expect(pending.contains("\\n"))
        #expect(pending.contains("\\u0008"))
        #expect(pending.unicodeScalars.contains { $0.value == 0x0B } == false)
        #expect(pending.unicodeScalars.contains { $0.value == 0x08 } == false)
        Self.expectNoForgedReviewLine(pending, trailer: trailer)
        let pendingLines = pending.split(whereSeparator: \.isNewline).map(String.init)
        #expect(pendingLines.contains(trailer) == false)

        let reason = Mutex("")
        let presence = UserPresence { why, challenge in
            reason.withLock { $0 = why }
            guard case .printedCode(let check) = challenge, check(code) else {
                return .refused("wrong confirmation code")
            }
            return .confirmed(method: "terminal confirmation code")
        }
        let approved = try await MCPRun.approve(
            id: ticket.id, always: false, environment: fixture.environment(presence: presence)).get()
        let shown = reason.withLock { $0 }
        #expect(shown.contains("\\u000b"))
        #expect(shown.contains("\\n"))
        #expect(shown.contains("\\u0008"))
        #expect(shown.unicodeScalars.contains { $0.value == 0x0B } == false)
        #expect(shown.unicodeScalars.contains { $0.value == 0x0A } == false)
        #expect(shown.unicodeScalars.contains { $0.value == 0x08 } == false)
        Self.expectNoForgedReviewLine(shown, trailer: trailer)
        #expect(shown.split(whereSeparator: \.isNewline).map(String.init).contains(trailer) == false)
        #expect(approved.contains("\\u000b"))
        #expect(approved.unicodeScalars.contains { $0.value == 0x0B } == false)
        Self.expectNoForgedReviewLine(approved, trailer: trailer)
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

    @Test func launchUsesTheBytesVerifiedDuringTheKeyPrompt() throws {
        let fixture = Fixture()
        try signedConfiguration(fixture, MCPConfiguration(servers: [
            MCPServerDefinition(name: "fs", command: "fs-mcp", secrets: ["TOKEN": "GH"])
        ]))
        let url = MCPConfiguration.fileURL(configDirectory: fixture.config)
        let trusted = try Data(contentsOf: url)
        try plant(trustedReplacing("fs-mcp", with: "evil-binary", in: trusted), at: url)
        let calls = Mutex(0)
        let resolver = SecretResolver { _ in
            calls.withLock { $0 += 1 }
            guard let value = SecretValue("resolved-value") else { return .failure(.invalidValue("test secret")) }
            return .success(value)
        }
        let secrets = SecretsConfiguration(secrets: [
            SecretDefinition(name: "GH", source: .hostEnvironment(variable: "GH"), delivery: .environment)
        ])

        let early = try MCPRun.configuration(fixture.environment()).get()
        #expect(early.server(named: "fs")?.command == "evil-binary")
        let restoredDuringPrompt = keysReplacing(fixture, with: trusted, onCall: 1)
        let duringPrompt = MCPRun.upstreamLaunches(
            names: ["fs"], configuration: early, environment: fixture.environment(approvalKeys: restoredDuringPrompt),
            secrets: secrets, resolver: resolver)
        #expect(duringPrompt.failureMessage?.contains("edited outside rv") == true)
        #expect(duringPrompt.failureMessage?.contains("not launching MCP servers") == true)
        #expect(calls.withLock { $0 } == 0)

        try plant(trustedReplacing("fs-mcp", with: "evil-binary", in: trusted), at: url)
        let swapping = keysReplacing(fixture, with: trusted, onCall: 1)
        let captured = try MCPRun.configuration(fixture.environment(approvalKeys: swapping)).get()
        #expect(captured.server(named: "fs")?.command == "evil-binary")
        let later = MCPRun.upstreamLaunches(
            names: ["fs"], configuration: captured, environment: fixture.environment(approvalKeys: swapping),
            secrets: secrets, resolver: resolver)
        #expect(later.failureMessage?.contains("changed while it was being checked") == true)
        #expect(later.failureMessage?.contains("not launching MCP servers") == true)
        #expect(calls.withLock { $0 } == 0)
        #expect(later.failureMessage?.contains("evil-binary") == false)
    }

    @Test func approveAlwaysSignsTheConfigurationReadBeforeTheKeyPrompt() async throws {
        let fixture = Fixture()
        try signedConfiguration(fixture, MCPConfiguration(servers: [
            MCPServerDefinition(name: "fs", command: "fs-mcp", tools: MCPToolPolicy(ask: ["write_file"]))
        ]))
        let url = MCPConfiguration.fileURL(configDirectory: fixture.config)
        let trusted = try Data(contentsOf: url)
        let evil = trustedReplacing("fs-mcp", with: "evil-binary", in: trusted)
        let ticket = try #require(fixture.environment().approvals.request(
            server: "fs", tool: "write_file", argumentsHash: "h2", argumentKeys: []) )
        let code = try #require(ticket.code)
        let swapping = keysReplacing(fixture, with: evil, onCall: 1)
        let approved = try await MCPRun.approve(
            id: ticket.id, always: true,
            environment: fixture.environment(presence: Self.typing { code }, approvalKeys: swapping)
        ).get()
        #expect(approved.contains("always"))
        let text = fixture.text(".config/rv/mcp.json")
        #expect(text.contains("fs-mcp"))
        #expect(text.contains("evil-binary") == false)
        let loaded = try MCPRun.configuration(fixture.environment()).get()
        let fs = try #require(loaded.server(named: "fs"))
        #expect(fs.command == "fs-mcp")
        #expect(fs.tools.allow == ["write_file"])
        #expect(fixture.environment().integrity == .trusted)

        try plant(evil, at: url)
        let again = try #require(fixture.environment().approvals.request(
            server: "fs", tool: "write_file", argumentsHash: "h3", argumentKeys: [])?.id)
        let restoring = keysReplacing(fixture, with: trusted, onCall: 1)
        let refused = await MCPRun.approve(
            id: again, always: true, environment: fixture.environment(approvalKeys: restoring))
        #expect(refused.failureMessage?.contains("edited outside rv") == true)
        let after = try MCPRun.configuration(fixture.environment()).get()
        #expect(after.server(named: "fs")?.command == "fs-mcp")
        #expect(fixture.text(".config/rv/mcp.json").contains("evil-binary") == false)
    }

    @Test func importSignsTheSnapshotVerifiedBeforeTheKeyPrompt() async throws {
        let fixture = Fixture()
        try signedConfiguration(fixture, MCPConfiguration(servers: [
            MCPServerDefinition(name: "kept", command: "safe-bin")
        ]))
        try fixture.write(".cursor/mcp.json", Self.cursorConfig)
        let url = MCPConfiguration.fileURL(configDirectory: fixture.config)
        let trusted = try Data(contentsOf: url)
        let evil = trustedReplacing("safe-bin", with: "evil-binary", in: trusted)
        let swapping = keysReplacing(fixture, with: evil, onCall: 1)
        let imported = try await MCPRun.importServers(
            host: .cursor, names: ["seq"], project: nil, allowTools: false, dryRun: false,
            environment: fixture.environment(approvalKeys: swapping)
        ).get()
        #expect(imported.contains("wrote mcp.json"))
        let text = fixture.text(".config/rv/mcp.json")
        #expect(text.contains("safe-bin"))
        #expect(text.contains("evil-binary") == false)
        #expect(text.contains("\"seq\""))
        #expect(fixture.environment().integrity == .trusted)

        try signedConfiguration(fixture, MCPConfiguration(servers: [
            MCPServerDefinition(name: "kept", command: "safe-bin")
        ]))
        try plant(trustedReplacing("safe-bin", with: "evil-binary", in: try Data(contentsOf: url)), at: url)
        let restoring = keysReplacing(fixture, with: trusted, onCall: 1)
        let refused = await MCPRun.importServers(
            host: .cursor, names: ["github"], project: nil, allowTools: false, dryRun: false,
            environment: fixture.environment(approvalKeys: restoring))
        #expect(refused.failureMessage?.contains("edited outside rv") == true)
        #expect(refused.failureMessage?.contains("nothing imported") == true)
        #expect(fixture.text(".config/rv/mcp.json").contains("\"github\"") == false)
        #expect(fixture.text(".config/rv/mcp.json").contains("evil-binary") == false)
        let kept = try MCPRun.configuration(fixture.environment()).get().server(named: "kept")
        #expect(kept?.command == "safe-bin")
    }

    @Test func importPresenceListsEveryServerBeforeConfirm() async throws {
        let fixture = Fixture()
        let long = String(repeating: "A", count: 300)
        try fixture.write(".cursor/mcp.json", """
            {"mcpServers": {
              "first": {"command": "long-cmd", "args": ["\(long)"]},
              "second": {"command": "hidden-cmd", "args": ["--flag"]}
            }}
            """)
        let shown = Mutex("")
        let reasonAtPrompt = Mutex("")
        let shownBeforePrompt = Mutex(false)
        let watching = UserPresence { reason, challenge in
            guard case .deviceOwner = challenge else { return .refused("not device owner") }
            let already = shown.withLock { $0 }
            shownBeforePrompt.withLock { $0 = already.contains("second:") && already.contains("hidden-cmd") }
            reasonAtPrompt.withLock { $0 = reason }
            return .confirmed(method: "device owner authentication")
        }
        let imported = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: true, dryRun: false,
            environment: fixture.environment(presence: watching),
            show: { text in shown.withLock { $0 = text } }
        ).get()
        let reason = reasonAtPrompt.withLock { $0 }
        let review = shown.withLock { $0 }
        #expect(shownBeforePrompt.withLock { $0 })
        #expect(review.contains("tools: allow every tool"))
        #expect(review.contains("first: long-cmd \(long)"))
        #expect(review.contains("second: hidden-cmd --flag"))
        #expect(reason.contains("tools: allow every tool"))
        #expect(reason.contains("first: long-cmd \(long)"))
        #expect(reason.contains("second: hidden-cmd --flag"))
        #expect(reason.contains("ask before every tool") == false)
        #expect(reason.count > 240)
        #expect(reason.hasSuffix("…") == false)
        let parts = review.components(separatedBy: "\nsha256 ")
        let body = parts.first ?? ""
        let expected = RVDigest.sha256Hex(Array(body.utf8))
        #expect(parts.count == 2)
        #expect(parts.dropFirst().first?.hasPrefix(expected) == true)
        #expect(reason.contains("sha256 \(expected)"))
        #expect(reason.contains(body))
        #expect(imported.contains("wrote mcp.json"))
        let loaded = try MCPRun.configuration(fixture.environment()).get()
        #expect(loaded.server(named: "first")?.command == "long-cmd")
        #expect(loaded.server(named: "second")?.command == "hidden-cmd")
        #expect(loaded.server(named: "second")?.tools.defaultDecision == .allow)
    }

    @Test func importAskIsNotOverriddenByAFileAllow() async throws {
        let fixture = Fixture()
        try signedConfiguration(fixture, MCPConfiguration(defaultDecision: .allow, servers: [
            MCPServerDefinition(name: "kept", command: "safe-bin")
        ]))
        try fixture.write(".cursor/mcp.json", """
            {"mcpServers": {
              "notes": {"command": "git", "args": ["status"], "env": {
                "PATH": "/tmp/evil",
                "GIT_SSH_COMMAND": "evil-ssh",
                "LD_PRELOAD": "/tmp/p.so",
                "GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
              }}
            }}
            """)
        let shown = Mutex("")
        let reasonAtPrompt = Mutex("")
        let watching = UserPresence { reason, challenge in
            guard case .deviceOwner = challenge else { return .refused("not device owner") }
            reasonAtPrompt.withLock { $0 = reason }
            return .confirmed(method: "device owner authentication")
        }
        let imported = try await MCPRun.importServers(
            host: .cursor, names: ["notes"], project: nil, allowTools: false, dryRun: false,
            environment: fixture.environment(presence: watching),
            show: { text in shown.withLock { $0 = text } }
        ).get()
        let reason = reasonAtPrompt.withLock { $0 }
        let review = shown.withLock { $0 }
        for text in [reason, review] {
            #expect(text.contains("ask before every tool"))
            #expect(text.contains("env PATH=/tmp/evil"))
            #expect(text.contains("env GIT_SSH_COMMAND=evil-ssh"))
            #expect(text.contains("env LD_PRELOAD=/tmp/p.so"))
            #expect(text.contains("secret GITHUB_TOKEN=GITHUB_TOKEN"))
            #expect(text.contains("ghp_") == false)
            #expect(text.contains("allow every tool") == false)
        }
        #expect(imported.contains("wrote mcp.json"))
        let loaded = try MCPRun.configuration(fixture.environment()).get()
        #expect(loaded.defaultDecision == .allow)
        let notes = try #require(loaded.server(named: "notes"))
        #expect(notes.tools.defaultDecision == .ask)
        #expect(loaded.decision(server: notes, tool: "status") == .ask)
        let kept = try #require(loaded.server(named: "kept"))
        #expect(kept.tools.defaultDecision == nil)
        #expect(loaded.decision(server: kept, tool: "anything") == .allow)
        let stored = fixture.text(".config/rv/mcp.json")
        #expect(stored.contains("/tmp/evil"))
        #expect(stored.contains("ghp_") == false)
    }

    @Test func trustPromptListsEveryBindingAndEveryAllowName() async throws {
        let fixture = Fixture()
        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(
                name: "notes", command: "git", args: ["status"],
                environment: ["PATH": "/tmp/evil", "GIT_SSH_COMMAND": "evil-ssh", "LD_PRELOAD": "/tmp/p.so"],
                secrets: ["GITHUB_TOKEN": "NOTES_GITHUB_TOKEN"],
                tools: MCPToolPolicy(allow: ["one", "two", "three", "four", "five"]))
        ])
        let url = try fixture.write(".config/rv/mcp.json", configuration.encoded().prettyText)
        chmod(url.path, 0o600)
        chmod(fixture.config.path, 0o700)
        let digest = RVDigest.sha256Hex([UInt8](try Data(contentsOf: url)))
        let shown = Mutex("")
        let challenges = Mutex<[String]>([])
        let presence = UserPresence { reason, challenge in
            guard case .deviceOwner = challenge else { return .refused("not device owner") }
            challenges.withLock { $0.append(reason) }
            return .confirmed(method: "device owner authentication")
        }
        let trusted = try await MCPRun.trust(
            environment: fixture.environment(presence: presence), show: { text in shown.withLock { $0 += text } }
        ).get()
        let reason = challenges.withLock { $0 }.joined(separator: "\n")
        let review = shown.withLock { $0 }
        for text in [reason, review] {
            #expect(text.contains(digest))
            #expect(text.contains("notes: git status"))
            #expect(text.contains("env PATH=/tmp/evil"))
            #expect(text.contains("env GIT_SSH_COMMAND=evil-ssh"))
            #expect(text.contains("env LD_PRELOAD=/tmp/p.so"))
            #expect(text.contains("secret GITHUB_TOKEN=NOTES_GITHUB_TOKEN"))
            #expect(text.contains("allow one, two, three, four, five"))
            #expect(text.contains("no sandbox"))
            #expect(text.range(of: #"\+\d+ more"#, options: .regularExpression) == nil)
        }
        #expect(reason.contains("rv: trust mcp.json sha256 \(digest)\n"))
        #expect(reason.contains("mcp.json: default"))
        #expect(trusted.contains("trusted mcp.json"))
    }

    @Test func trustAndImportShowSandboxAndKeepNewlinesInsideFields() async throws {
        let zeros = String(repeating: "0", count: 64)
        let trailer = "sha256 \(zeros)"
        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(
                name: "closed", command: "/bin/echo",
                args: ["\n  notes: /usr/bin/true"],
                environment: ["NOTE": "/usr/bin\n\(trailer)\n  hidden: true"],
                tools: MCPToolPolicy(defaultDecision: .ask, allow: ["read\n\(trailer)"]),
                sandbox: MCPSandboxPolicy(network: false, writable: ["/Users/me/proj\n\(trailer)"])
            ),
            MCPServerDefinition(
                name: "open", command: "/bin/true",
                sandbox: MCPSandboxPolicy(network: true, writable: ["/"])
            ),
            MCPServerDefinition(name: "bare", command: "/bin/cat"),
        ])
        let fixture = Fixture()
        let url = try fixture.write(".config/rv/mcp.json", configuration.encoded().prettyText)
        chmod(url.path, 0o600)
        chmod(fixture.config.path, 0o700)
        let digest = RVDigest.sha256Hex([UInt8](try Data(contentsOf: url)))
        let shown = Mutex("")
        let reasonAtPrompt = Mutex("")
        let presence = UserPresence { reason, challenge in
            guard case .deviceOwner = challenge else { return .refused("not device owner") }
            reasonAtPrompt.withLock { $0 = reason }
            return .confirmed(method: "device owner authentication")
        }
        let trusted = try await MCPRun.trust(
            environment: fixture.environment(presence: presence), show: { text in shown.withLock { $0 = text } }
        ).get()
        let reason = reasonAtPrompt.withLock { $0 }
        let review = shown.withLock { $0 }
        for text in [reason, review] {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            #expect(lines.contains { $0.hasSuffix("sandbox network false") })
            #expect(lines.contains { $0.hasSuffix("sandbox network true") })
            #expect(lines.contains { line in
                line.contains("sandbox writable ")
                    && line.contains("~/Library/Caches/rv-mcp/closed")
                    && line.contains("TMPDIR")
                    && line.contains("/private/tmp")
                    && line.contains("/dev")
                    && line.hasSuffix("/Users/me/proj\\n\(trailer)")
            })
            #expect(lines.contains { line in
                line.contains("sandbox writable ")
                    && line.contains("~/Library/Caches/rv-mcp/open")
                    && line.contains("TMPDIR")
                    && line.contains("/private/tmp")
                    && line.contains("/dev")
                    && line.contains("~/.cache")
                    && line.contains("~/Library/Caches")
                    && line.hasSuffix(", /")
                    && line.contains("proj") == false
            })
            #expect(text.contains("writable none") == false)
            #expect(lines.contains { $0.hasSuffix("no sandbox") })
            #expect(text.contains("other tools ask"))
            #expect(text.contains("bare: /bin/cat"))
            #expect(text.contains("\\n  notes: /usr/bin/true"))
            #expect(text.contains("\\n  hidden: true"))
            #expect(text.contains("allow read\\n\(trailer)"))
            Self.expectNoForgedReviewLine(text, trailer: trailer)
        }
        let shownLines = review.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(shownLines.filter { $0.hasPrefix("sha256 ") } == ["sha256 \(digest)"])
        #expect(reason.contains("rv: trust mcp.json sha256 \(digest)\n"))
        #expect(trusted.contains("trusted mcp.json"))

        try fixture.write(".cursor/mcp.json", """
            {"mcpServers": {
              "first": {"command": "/bin/echo", "args": ["\\n  notes: /usr/bin/true"],
                "env": {"NOTE": "/usr/bin\\nsha256 \(zeros)\\n  hidden: true"}},
              "later": {"command": "/usr/bin/true", "args": ["--ok"]}
            }}
            """)
        let importShown = Mutex("")
        let importReason = Mutex("")
        let importing = UserPresence { reason, challenge in
            guard case .deviceOwner = challenge else { return .refused("not device owner") }
            importReason.withLock { $0 = reason }
            return .confirmed(method: "device owner authentication")
        }
        let imported = try await MCPRun.importServers(
            host: .cursor, names: [], project: nil, allowTools: false, dryRun: false,
            environment: fixture.environment(presence: importing),
            show: { text in importShown.withLock { $0 = text } }
        ).get()
        let importedReason = importReason.withLock { $0 }
        let importedReview = importShown.withLock { $0 }
        for text in [importedReason, importedReview] {
            #expect(text.contains("first: /bin/echo \\n  notes: /usr/bin/true"))
            #expect(text.contains("env NOTE=/usr/bin\\n\(trailer)\\n  hidden: true"))
            #expect(text.contains("later: /usr/bin/true --ok"))
            #expect(text.contains("no sandbox"))
            #expect(text.contains("ask before every tool"))
            Self.expectNoForgedReviewLine(text, trailer: trailer)
        }
        let importLines = importedReview.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(importLines.filter { $0.hasPrefix("sha256 ") }.count == 1)
        let body = importedReview.components(separatedBy: "\nsha256 ").first ?? ""
        #expect(body.contains("later: /usr/bin/true --ok"))
        #expect(body.contains("no sandbox"))
        #expect(imported.contains("wrote mcp.json"))
    }

    @Test func emptySandboxWritableStillShowsTheSeatbeltWriteAllow() async throws {
        let server = MCPServerDefinition(
            name: "caged", command: "/bin/true",
            sandbox: MCPSandboxPolicy(network: false, writable: []))
        let configuration = MCPConfiguration(servers: [server])
        let imported = MCPRun.importPresenceReview(servers: [server], allowTools: false)
        let fixture = Fixture()
        let url = try fixture.write(".config/rv/mcp.json", configuration.encoded().prettyText)
        chmod(url.path, 0o600)
        chmod(fixture.config.path, 0o700)
        let shown = Mutex("")
        let reasonAtPrompt = Mutex("")
        let presence = UserPresence { reason, challenge in
            guard case .deviceOwner = challenge else { return .refused("not device owner") }
            reasonAtPrompt.withLock { $0 = reason }
            return .confirmed(method: "device owner authentication")
        }
        _ = try await MCPRun.trust(
            environment: fixture.environment(presence: presence), show: { text in shown.withLock { $0 = text } }
        ).get()
        let paths = [
            "~/Library/Caches/rv-mcp/caged", "TMPDIR", "/private/tmp", "/private/var/folders", "/dev",
            "~/.npm", "~/.cache", "~/Library/Caches",
        ]
        for text in [shown.withLock { $0 }, reasonAtPrompt.withLock { $0 }, imported.shown, imported.reason] {
            #expect(text.contains("writable none") == false)
            #expect(text.contains("sandbox network false"))
            for path in paths {
                #expect(text.contains(path), "missing \(path)")
            }
        }
    }

    @Test func trustReviewEscapesTerminalRedrawAndUnicodeLineBreaks() async throws {
        let trailer = "sha256 " + String(repeating: "a", count: 64)
        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(
                name: "closed", command: "/bin/echo",
                args: ["\u{000B}\(trailer)"],
                environment: ["NOTE": "\u{000C}\(trailer)", "OTHER": "\u{0085}  hidden: true"],
                sandbox: MCPSandboxPolicy(network: false, writable: ["/tmp/\u{001B}[2J\u{0008}\(trailer)"]))
        ])
        let fixture = Fixture()
        let url = try fixture.write(".config/rv/mcp.json", configuration.encoded().prettyText)
        chmod(url.path, 0o600)
        chmod(fixture.config.path, 0o700)
        let shown = Mutex("")
        let reasonAtPrompt = Mutex("")
        let presence = UserPresence { reason, challenge in
            guard case .deviceOwner = challenge else { return .refused("not device owner") }
            reasonAtPrompt.withLock { $0 = reason }
            return .confirmed(method: "device owner authentication")
        }
        _ = try await MCPRun.trust(
            environment: fixture.environment(presence: presence), show: { text in shown.withLock { $0 = text } }
        ).get()
        let imported = MCPRun.importPresenceReview(servers: configuration.servers, allowTools: false)
        for text in [shown.withLock { $0 }, reasonAtPrompt.withLock { $0 }, imported.shown, imported.reason] {
            let scalars = Set(text.unicodeScalars.map(\.value))
            #expect(scalars.contains(0x08) == false)
            #expect(scalars.contains(0x0B) == false)
            #expect(scalars.contains(0x0C) == false)
            #expect(scalars.contains(0x1B) == false)
            #expect(scalars.contains(0x85) == false)
            #expect(text.contains("\\u0008"))
            #expect(text.contains("\\u000b"))
            #expect(text.contains("\\u000c"))
            #expect(text.contains("\\u001b"))
            #expect(text.contains("\\u0085"))
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            #expect(lines.contains(trailer) == false)
            #expect(lines.contains("  hidden: true") == false)
        }
    }

    private static func expectNoForgedReviewLine(_ text: String, trailer: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains(trailer) == false)
        #expect(lines.contains("  hidden: true") == false)
        #expect(lines.contains("  notes: /usr/bin/true") == false)
        #expect(lines.contains { $0.hasPrefix("  hidden:") } == false)
    }

    @Test func rvPathIsAbsoluteAndFoundOnPath() throws {
        #expect(MCPRun.rvExecutablePath(arguments: ["/usr/local/bin/rv"], environment: [:]) == "/usr/local/bin/rv")
        #expect(MCPRun.rvExecutablePath(arguments: ["sh"], environment: ["PATH": "/nope:/bin"]) == "/bin/sh")
        let relative = MCPRun.rvExecutablePath(arguments: ["./rv"], environment: [:])
        #expect(relative.hasPrefix("/") && relative.hasSuffix("/rv") && relative.contains("./") == false)
    }

    private func keysReplacing(_ fixture: Fixture, with replacement: Data, onCall call: Int) -> MCPApprovalKeyStore {
        let backing = MCPApprovalKeyStore.file(configDirectory: fixture.config)
        let url = MCPConfiguration.fileURL(configDirectory: fixture.config)
        let seen = Mutex(0)
        let swap: @Sendable () -> Void = {
            let n = seen.withLock { count -> Int in
                count += 1
                return count
            }
            guard n == call else { return }
            try? replacement.write(to: url, options: .atomic)
            chmod(url.path, 0o600)
        }
        return MCPApprovalKeyStore(
            load: {
                swap()
                return backing.load()
            },
            loadOrCreate: {
                swap()
                return backing.loadOrCreate()
            })
    }

    private func plant(_ data: Data, at url: URL) throws {
        try data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    private func trustedReplacing(_ name: String, with command: String, in data: Data) -> Data {
        Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: name, with: command).utf8)
    }
}

private extension Result where Failure == CommandFailure {
    var failureMessage: String? {
        if case .failure(let failure) = self { return failure.message }
        return nil
    }
}
