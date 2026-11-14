import Foundation
import RVHistory
import RVMCP
import Testing
@testable import RVCLI

/// `rv mcp serve` writes each call's audit record before forwarding it, and
/// reports a write it could not make so the gateway refuses the call.
@Suite("rv mcp serve forward audit")
struct MCPForwardAuditTests {
    static let record = MCPCallRecord(
        server: "github", tool: "search", decision: .allow, argumentKeys: ["q"], isError: false,
        outcome: .forwarding(grant: nil))

    @Test func theForwardRecordIsAppendedBeforeTheCallRuns() {
        let fixture = MCPCommandTests.Fixture()
        #expect(MCPRun.recordForward(Self.record, configDirectory: fixture.config))
        let events = AuditLedger(configDirectory: fixture.config).events(AuditFilter(kinds: [AuditEventKind.mcpCall.rawValue]))
        #expect(events.count == 1)
        #expect(events.first?.subject == "github/search")
        #expect(events.first?.decision == .allowed)
        #expect(events.first?.detail["stage"] == "forward")
    }

    @Test func anAuditLogThatCannotBeWrittenReportsFailure() throws {
        let fixture = MCPCommandTests.Fixture()
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let blocker = fixture.root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        #expect(MCPRun.recordForward(Self.record, configDirectory: blocker.appendingPathComponent("rv")) == false)
    }
}
