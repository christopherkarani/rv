#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Dispatch
import Foundation
import RVHistory
import RVMCP
import Synchronization
import Testing
@testable import RVCLI

/// `rv mcp serve` checks the host configs once before serving and warns
/// when some run MCP servers around the gateway or hold unreviewed ones.
@Suite("rv mcp serve host check")
struct MCPServeHostCheckTests {
    final class Sink: Sendable {
        let lines = Mutex<[String]>([])
        let events = Mutex<[AuditEvent]>([])

        var log: @Sendable (String) -> Void { { line in self.lines.withLock { $0.append(line) } } }

        func audit(succeeds: Bool) -> @Sendable (AuditEvent) -> Bool {
            { event in
                self.events.withLock { $0.append(event) }
                return succeeds
            }
        }
    }

    /// Counts every use of the approvals key, the seam `MCPIntegrity` and
    /// the custodian sit behind.
    final class SigningCalls: Sendable {
        let count = Mutex(0)

        var signing: MCPApprovalSigning {
            MCPApprovalSigning(
                status: {
                    self.count.withLock { $0 += 1 }
                    return .notEnrolled
                },
                mac: { _, _, _ in
                    self.count.withLock { $0 += 1 }
                    return nil
                },
                verify: { _, _, _ in
                    self.count.withLock { $0 += 1 }
                    return .noKey
                },
                beginFreshAuth: { self.count.withLock { $0 += 1 } })
        }
    }

    /// ESC, CSI erase and a bidi override: text a terminal would act on.
    static let hostile = "evil" + String(Unicode.Scalar(UInt8(0x1B))) + "[2J" + String(Unicode.Scalar(0x202E)!) + "name"
    static let counts = MCPRun.HostCheckCounts(bypass: 2, blocked: 1, unreviewed: 1)
    static let notice = "host MCP configs hold 4 entries rv does not govern (2 bypass the gateway, "
        + "1 blocked in mcp.json but still run, 1 unreviewed); run `rv mcp check` to see them"
    /// For paths that must finish in time: a starved test run can take
    /// seconds to start the check's thread, and that is not what they test.
    static let generous: TimeInterval = 60

    @Test func ungovernedEntriesWriteOneCountedLineAndOneEvent() throws {
        let sink = Sink()
        MCPRun.checkHosts(timeout: Self.generous, count: { Self.counts }, log: sink.log, audit: sink.audit(succeeds: true))
        #expect(sink.lines.withLock { $0 } == [Self.notice])
        let events = sink.events.withLock { $0 }
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.kind == .mcpHostsUngoverned)
        #expect(event.decision == .info)
        #expect(event.source == "mcp-gateway")
        #expect(event.subject == "mcp-hosts")
        #expect(event.reason == Self.notice)
        #expect(event.detail == ["bypass": "2", "blocked": "1", "unreviewed": "1"])
    }

    @Test func oneEntrySaysSoInTheSingular() {
        let sink = Sink()
        MCPRun.checkHosts(
            timeout: Self.generous, count: { MCPRun.HostCheckCounts(bypass: 0, blocked: 0, unreviewed: 1) }, log: sink.log,
            audit: sink.audit(succeeds: true))
        #expect(sink.lines.withLock { $0 } == [
            "host MCP configs hold 1 entry rv does not govern (0 bypass the gateway, "
                + "0 blocked in mcp.json but still run, 1 unreviewed); run `rv mcp check` to see them"
        ])
    }

    @Test func noUngovernedEntryWritesNothing() {
        let sink = Sink()
        MCPRun.checkHosts(
            timeout: Self.generous, count: { MCPRun.HostCheckCounts() }, log: sink.log, audit: sink.audit(succeeds: true))
        #expect(sink.lines.withLock { $0 }.isEmpty)
        #expect(sink.events.withLock { $0 }.isEmpty)
    }

    /// A failed audit write does not change the warning or stop serving;
    /// stderr says the audit log could not take it, as for every other
    /// `rv mcp serve` event.
    @Test func aFailedAuditWriteChangesNothingElse() {
        let failed = Sink()
        MCPRun.checkHosts(
            timeout: Self.generous, count: { Self.counts }, log: failed.log, audit: failed.audit(succeeds: false))
        #expect(failed.events.withLock { $0.count } == 1)
        #expect(failed.lines.withLock { $0 } == [Self.notice, "could not append the audit log"])
    }

    /// The audit append shares the check's deadline: one that has not
    /// finished by then is left running, and serving goes on. The append is
    /// held until `checkHosts` has returned, so it returns with the append
    /// still running whatever the machine's load; the count, which is
    /// immediate, has the whole 3 s.
    @Test func aLateAuditWriteDoesNotHoldServingPastTheDeadline() {
        let sink = Sink()
        let release = DispatchSemaphore(value: 0)
        let finished = Mutex(false)
        MCPRun.checkHosts(
            timeout: 3, count: { Self.counts }, log: sink.log,
            audit: { _ in
                // Bounded, so a regressed deadline fails this test instead of hanging it.
                _ = release.wait(timeout: .now() + 30)
                finished.withLock { $0 = true }
                return true
            })
        #expect(finished.withLock { $0 } == false)
        release.signal()
        #expect(sink.lines.withLock { $0 } == [Self.notice, "audit append still running after 3 s; serving without waiting"])
    }

    /// The check never holds serving past its timeout: a count that has not
    /// finished is abandoned with one stderr line and no event.
    @Test func aCheckPastItsTimeoutSaysSoOnceAndReturns() {
        let sink = Sink()
        let release = DispatchSemaphore(value: 0)
        let started = Date()
        MCPRun.checkHosts(
            timeout: 0.05,
            count: {
                // Bounded, so a regressed deadline fails this test instead of hanging it.
                _ = release.wait(timeout: .now() + 10)
                return Self.counts
            },
            log: sink.log, audit: sink.audit(succeeds: true))
        let waited = Date().timeIntervalSince(started)
        // Checked before the abandoned worker is released: it may still
        // write its event afterwards, into this sink only.
        #expect(sink.events.withLock { $0 }.isEmpty)
        release.signal()
        #expect(waited < 5)
        #expect(sink.lines.withLock { $0 } == [
            "still checking host MCP configs after 0.05 s; serving without waiting; run `rv mcp check` to see them"
        ])
    }

    /// A blocked server the host launches through `rv mcp serve` is refused
    /// there, so it is not counted; launched by the host itself it is, and a
    /// disabled one is not.
    @Test func aBlockedEntryCountsOnlyWhenTheHostRunsItItself() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-blocked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rv = root.appendingPathComponent("rv")
        try Data("#!/bin/sh\n".utf8).write(to: rv)
        chmod(rv.path, 0o755)
        let configuration = try MCPConfiguration.decode(Data(#"{"version":1,"servers":[{"name":"wax","command":"wax-mcp"}],"blocked":["blk"]}"#.utf8)).get()
        func entry(_ name: String, _ transport: MCPTransport, disabled: Bool = false) -> MCPHostEntry {
            MCPHostEntry(
                host: .cursor, scope: .user, configPath: root.appendingPathComponent("mcp.json").path, name: name,
                transport: transport, isDisabled: disabled)
        }
        let throughRV = entry("blk", .stdio(command: rv.path, args: ["mcp", "serve", "--server", "blk"]))
        let direct = entry("blk", .stdio(command: "npx", args: ["blk-mcp"]))
        let disabled = entry("blk", .stdio(command: "npx", args: ["blk-mcp"]), disabled: true)
        let rows = [throughRV, direct, disabled].map {
            MCPInventoryRow.row($0, configuration: configuration, rvExecutable: rv.path)
        }
        #expect(rows.map(\.status) == [.blocked, .blocked, .blocked])
        #expect(MCPRun.hostCheckCounts([rows[0]], rvExecutable: rv.path) == MCPRun.HostCheckCounts())
        #expect(MCPRun.hostCheckCounts(rows, rvExecutable: rv.path) == MCPRun.HostCheckCounts(blocked: 1))
    }

    /// What `rv mcp serve` runs, against a temporary home and a temporary
    /// managed directory: bypass, unreviewed and blocked-but-run host
    /// entries are counted (a disabled blocked one, a direct one and none
    /// of their text are not), an entry in that managed directory is read,
    /// one event lands in that home's audit log, and the approvals key
    /// (integrity, custodian) is never used.
    @Test func serveCountsTheHostEntriesOfItsHomeWithoutTheApprovalsKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-serve-hosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let managed = root.appendingPathComponent("managed")
        let config = home.appendingPathComponent(".config/rv")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let mcpJSON = config.appendingPathComponent("mcp.json")
        try Data(#"{"version":1,"servers":[{"name":"wax","command":"wax-mcp"}],"direct":["dir"],"blocked":["blk","off"]}"#.utf8)
            .write(to: mcpJSON)
        chmod(mcpJSON.path, 0o600)
        chmod(config.path, 0o700)
        let cursor = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: cursor.deletingLastPathComponent(), withIntermediateDirectories: true)
        let npx = RVMCP.JSONValue.object(["command": .string("npx")])
        let servers = RVMCP.JSONValue.object(["mcpServers": .object([
            Self.hostile: npx, "seq": npx, "wax": npx, "blk": npx, "dir": npx,
            "off": .object(["command": .string("npx"), "disabled": .bool(true)]),
        ])])
        try Data(servers.compactText.utf8).write(to: cursor)
        let managedMCP = RVMCP.JSONValue.object(["mcpServers": .object(["mgd": npx])])
        try Data(managedMCP.compactText.utf8).write(to: managed.appendingPathComponent("managed-mcp.json"))
        let calls = SigningCalls()
        let environment = MCPEnvironment(
            configDirectory: config, home: home, processEnvironment: [:], keychain: FakeKeychain().writer,
            approvalSigning: calls.signing, oauthTokens: .file(configDirectory: config))
        let configuration = try MCPRun.configuration(environment).get()
        calls.count.withLock { $0 = 0 }
        let sink = Sink()
        MCPRun.checkHostsBeforeServing(
            environment, configuration: configuration, project: nil, managedDirectory: managed.path,
            timeout: Self.generous, log: sink.log)
        #expect(calls.count.withLock { $0 } == 0)
        let lines = sink.lines.withLock { $0 }
        #expect(lines == [
            "host MCP configs hold 5 entries rv does not govern (1 bypass the gateway, "
                + "1 blocked in mcp.json but still run, 3 unreviewed); run `rv mcp check` to see them"
        ])
        let events = AuditLedger(configDirectory: config).events(
            AuditFilter(kinds: [AuditEventKind.mcpHostsUngoverned.rawValue]))
        #expect(events.count == 1)
        #expect(events.first?.detail == ["bypass": "1", "blocked": "1", "unreviewed": "3"])
        // Counts only: no text from a host config reaches stderr or the row.
        let row = String(decoding: try JSONEncoder().encode(events.first), as: UTF8.self)
        for text in lines + [row] {
            #expect(text.contains("evil") == false, "\(text)")
            #expect(text.contains("cursor") == false, "\(text)")
            #expect(MCPRun.reviewConceals(text) == false, "\(text)")
        }
    }
}
