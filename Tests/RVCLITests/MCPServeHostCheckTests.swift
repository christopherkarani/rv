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

    @Test func ungovernedEntriesWriteOneCountedLineAndOneEvent() throws {
        let sink = Sink()
        MCPRun.checkHosts(count: { Self.counts }, log: sink.log, audit: sink.audit(succeeds: true))
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
            count: { MCPRun.HostCheckCounts(bypass: 0, blocked: 0, unreviewed: 1) }, log: sink.log,
            audit: sink.audit(succeeds: true))
        #expect(sink.lines.withLock { $0 } == [
            "host MCP configs hold 1 entry rv does not govern (0 bypass the gateway, "
                + "0 blocked in mcp.json but still run, 1 unreviewed); run `rv mcp check` to see them"
        ])
    }

    @Test func noUngovernedEntryWritesNothing() {
        let sink = Sink()
        MCPRun.checkHosts(count: { MCPRun.HostCheckCounts() }, log: sink.log, audit: sink.audit(succeeds: true))
        #expect(sink.lines.withLock { $0 }.isEmpty)
        #expect(sink.events.withLock { $0 }.isEmpty)
    }

    /// A failed audit write does not change the warning or stop serving;
    /// stderr says the audit log could not take it, as for every other
    /// `rv mcp serve` event.
    @Test func aFailedAuditWriteChangesNothingElse() {
        let failed = Sink()
        MCPRun.checkHosts(count: { Self.counts }, log: failed.log, audit: failed.audit(succeeds: false))
        #expect(failed.events.withLock { $0.count } == 1)
        #expect(failed.lines.withLock { $0 } == [Self.notice, "could not append the audit log"])
    }

    /// The audit append shares the check's deadline: one that has not
    /// finished by then is left running, and serving goes on.
    @Test func aLateAuditWriteDoesNotHoldServingPastTheDeadline() {
        let sink = Sink()
        let release = DispatchSemaphore(value: 0)
        let started = Date()
        MCPRun.checkHosts(
            timeout: 0.2, count: { Self.counts }, log: sink.log,
            audit: { _ in
                // Bounded, so a regressed deadline fails this test instead of hanging it.
                _ = release.wait(timeout: .now() + 10)
                return true
            })
        let waited = Date().timeIntervalSince(started)
        release.signal()
        #expect(waited < 5)
        #expect(sink.lines.withLock { $0 } == [Self.notice, "could not append the audit log within 0.2 s"])
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
        release.signal()
        #expect(waited < 5)
        #expect(sink.lines.withLock { $0 } == [
            "could not check host MCP configs within 0.05 s; run `rv mcp check` to see them"
        ])
        #expect(sink.events.withLock { $0 }.isEmpty)
    }

    /// What `rv mcp serve` runs, against a temporary home and a temporary
    /// managed directory: bypass, unreviewed and blocked-but-run host
    /// entries are counted (a disabled blocked one, a direct one and none
    /// of their text are not), one event lands in that home's audit log,
    /// and the approvals key (integrity, custodian) is never used.
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
        let calls = SigningCalls()
        let environment = MCPEnvironment(
            configDirectory: config, home: home, processEnvironment: [:], keychain: FakeKeychain().writer,
            approvalSigning: calls.signing, oauthTokens: .file(configDirectory: config))
        let configuration = try MCPRun.configuration(environment).get()
        calls.count.withLock { $0 = 0 }
        let sink = Sink()
        MCPRun.checkHostsBeforeServing(
            environment, configuration: configuration, project: nil, managedDirectory: managed.path, log: sink.log)
        #expect(calls.count.withLock { $0 } == 0)
        let lines = sink.lines.withLock { $0 }
        #expect(lines == [
            "host MCP configs hold 4 entries rv does not govern (1 bypass the gateway, "
                + "1 blocked in mcp.json but still run, 2 unreviewed); run `rv mcp check` to see them"
        ])
        let events = AuditLedger(configDirectory: config).events(
            AuditFilter(kinds: [AuditEventKind.mcpHostsUngoverned.rawValue]))
        #expect(events.count == 1)
        #expect(events.first?.detail == ["bypass": "1", "blocked": "1", "unreviewed": "2"])
        // Counts only: no text from a host config reaches stderr or the row.
        let row = String(decoding: try JSONEncoder().encode(events.first), as: UTF8.self)
        for text in lines + [row] {
            #expect(text.contains("evil") == false, "\(text)")
            #expect(text.contains("cursor") == false, "\(text)")
            #expect(MCPRun.reviewConceals(text) == false, "\(text)")
        }
    }
}
