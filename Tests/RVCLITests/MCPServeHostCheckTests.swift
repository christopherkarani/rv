import Dispatch
import Foundation
import RVHistory
import RVMCP
import Synchronization
import Testing
@testable import RVCLI

/// `rv mcp serve` checks the host configs once before serving and warns
/// when some run MCP servers outside the gateway or hold unreviewed ones.
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

    /// ESC, CSI erase and a bidi override: text a terminal would act on.
    static let hostile = "evil" + String(Unicode.Scalar(UInt8(0x1B))) + "[2J" + String(Unicode.Scalar(0x202E)!) + "name"

    static func row(_ name: String, _ status: MCPEntryStatus) -> MCPRun.Row {
        MCPRun.Row(
            host: "cursor", scope: "user", configPath: "/home/" + name + "/.cursor/mcp.json", name: name,
            status: status.rawValue, command: name, environmentNames: [], headerNames: [], plaintextCredentials: [],
            governedServer: nil)
    }

    static func report(_ rows: [MCPRun.Row]) -> MCPRun.Report {
        MCPRun.Report(servers: 0, direct: 0, blocked: 0, integrity: "none", integrityProblem: nil, rows: rows, problems: [])
    }

    static let mixed = report([
        row(hostile, .bypass), row("b", .bypass), row("c", .unreviewed), row("g", .governed), row("d", .direct),
        row("x", .dangling), row("y", .blocked), row("z", .disabled),
    ])

    @Test func bypassAndUnreviewedEntriesWriteOneCountedLineAndOneEvent() throws {
        let sink = Sink()
        MCPRun.checkHosts(report: { Self.mixed }, log: sink.log, audit: sink.audit(succeeds: true))
        let lines = sink.lines.withLock { $0 }
        #expect(lines == [
            "host MCP configs hold 3 servers rv does not govern (2 bypass the gateway, 1 unreviewed); "
                + "run `rv mcp check` to see them"
        ])
        let events = sink.events.withLock { $0 }
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.kind == .mcpHostsUngoverned)
        #expect(event.decision == .info)
        #expect(event.source == "mcp-gateway")
        #expect(event.detail == ["bypass": "2", "unreviewed": "1"])
        // Counts only: no text from a host config reaches stderr or the row.
        let row = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        for text in lines + [row] {
            #expect(text.contains("evil") == false, "\(text)")
            #expect(text.contains("/home/") == false, "\(text)")
            #expect(MCPRun.reviewConceals(text) == false, "\(text)")
        }
    }

    @Test func oneEntrySaysSoInTheSingular() {
        let sink = Sink()
        MCPRun.checkHosts(report: { Self.report([Self.row("u", .unreviewed)]) }, log: sink.log, audit: sink.audit(succeeds: true))
        #expect(sink.lines.withLock { $0 } == [
            "host MCP configs hold 1 server rv does not govern (0 bypass the gateway, 1 unreviewed); "
                + "run `rv mcp check` to see them"
        ])
    }

    @Test func noBypassOrUnreviewedEntryWritesNothing() {
        let sink = Sink()
        let rows = [Self.row("g", .governed), Self.row("d", .direct), Self.row("x", .dangling), Self.row("z", .disabled)]
        MCPRun.checkHosts(report: { Self.report(rows) }, log: sink.log, audit: sink.audit(succeeds: true))
        MCPRun.checkHosts(report: { Self.report([]) }, log: sink.log, audit: sink.audit(succeeds: true))
        #expect(sink.lines.withLock { $0 }.isEmpty)
        #expect(sink.events.withLock { $0 }.isEmpty)
    }

    /// A failed audit write does not change the warning or stop serving;
    /// stderr says the audit log could not take it, as for every other
    /// `rv mcp serve` event.
    @Test func aFailedAuditWriteChangesNothingElse() {
        let written = Sink()
        MCPRun.checkHosts(report: { Self.mixed }, log: written.log, audit: written.audit(succeeds: true))
        let failed = Sink()
        MCPRun.checkHosts(report: { Self.mixed }, log: failed.log, audit: failed.audit(succeeds: false))
        #expect(failed.events.withLock { $0.count } == 1)
        #expect(failed.lines.withLock { $0 } == written.lines.withLock { $0 } + ["could not append the audit log"])
    }

    /// The check never holds serving past its timeout: a report that has
    /// not finished is abandoned with one stderr line and no event.
    @Test func aCheckPastItsTimeoutSaysSoOnceAndReturns() {
        let sink = Sink()
        let release = DispatchSemaphore(value: 0)
        let started = Date()
        MCPRun.checkHosts(
            timeout: 0.05,
            report: {
                release.wait()
                return Self.mixed
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

    /// What `rv mcp serve` runs, against a temporary home: the report over
    /// the host configs there, one line, one event in that home's audit log.
    @Test func serveChecksTheHostConfigsOfItsHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-serve-hosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let config = home.appendingPathComponent(".config/rv")
        let cursor = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: cursor.deletingLastPathComponent(), withIntermediateDirectories: true)
        let servers = JSONValue.object(["mcpServers": .object([
            Self.hostile: .object(["command": .string("npx")]),
            "seq": .object(["command": .string("npx"), "args": .array([.string("-y"), .string("seq")])]),
        ])])
        try Data(servers.compactText.utf8).write(to: cursor)
        let environment = MCPEnvironment(
            configDirectory: config, home: home, processEnvironment: [:], keychain: FakeKeychain().writer,
            approvalSigning: .file(configDirectory: config), oauthTokens: .file(configDirectory: config))
        let configuration = try MCPRun.configuration(environment).get()
        let sink = Sink()
        MCPRun.checkHostsBeforeServing(environment, configuration: configuration, project: nil, log: sink.log)
        let lines = sink.lines.withLock { $0 }
        #expect(lines.count == 1)
        #expect(lines.first?.hasPrefix("host MCP configs hold 2 servers rv does not govern") == true)
        for line in lines {
            #expect(line.contains("evil") == false)
            #expect(MCPRun.reviewConceals(line) == false)
        }
        let events = AuditLedger(configDirectory: config).events(
            AuditFilter(kinds: [AuditEventKind.mcpHostsUngoverned.rawValue]))
        #expect(events.count == 1)
        #expect(events.first?.detail["unreviewed"] == "2")
        #expect(events.first.map { "\($0.subject) \($0.reason ?? "")".contains("evil") } == false)
    }
}
