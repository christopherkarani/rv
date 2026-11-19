import Foundation
import RVHistory
import Testing
@testable import RVMCP

/// Every refusal the MCP gateway records on its own carries its own OCSF
/// reason code. The gateway records them only through
/// `MCPGatewayCore.refused`, which takes an `MCPGatewayDenial`; a record
/// made with `decision: .deny` anywhere else fails here.
@Suite("MCP gateway denial codes")
struct MCPGatewayDenialCodeTests {
    @Test(arguments: MCPGatewayDenial.allCases)
    func everyDenialRecordsItsOwnCode(denial: MCPGatewayDenial) throws {
        guard case .audit(let record) = MCPGatewayCore.refused(
            denial, server: "fs", tool: "write", keys: ["path"], outcome: .notRun)
        else {
            Issue.record("refused(\(denial)) made no audit record")
            return
        }
        let event = record.auditEvent()
        #expect(event.decision == .denied)
        #expect(event.detail["policy"] == "deny")
        #expect(AuditReasonCode(event) == denial.code)
        #expect(denial.code != .mcpCallDeniedOther)
        let reason = try #require(event.reason)
        #expect(MCPGatewayDenial(recorded: reason) == denial)
    }

    @Test func everyDenialHasADistinctCode() {
        let codes = Set(MCPGatewayDenial.allCases.map(\.code))
        #expect(codes.count == MCPGatewayDenial.allCases.count)
    }

    /// The only `MCPCallRecord` built with `decision: .deny` in the sources
    /// is the one in `MCPGatewayCore.refused`.
    @Test func gatewayDeniesOnlyThroughRefused() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let denyRecord = try Regex(#"MCPCallRecord\((?:[^()]|\([^()]*\))*?decision:\s*(?:MCPToolDecision)?\.deny\b"#)
        let assigned = try Regex(#"\.decision\s*=\s*(?:MCPToolDecision)?\.deny\b"#)
        var sites: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let found = text.matches(of: denyRecord).count + text.matches(of: assigned).count
            if found > 0 { sites.append("\(url.lastPathComponent) x\(found)") }
        }
        #expect(sites == ["MCPGatewayCore.swift x1"], "deny records outside MCPGatewayCore.refused: \(sites)")
        let core = try String(
            contentsOf: sources.appendingPathComponent("RVMCP/MCPGatewayCore.swift"), encoding: .utf8)
        let helper = try #require(core.range(of: "static func refused("))
        let match = try #require(core.firstMatch(of: denyRecord))
        #expect(match.range.lowerBound > helper.lowerBound, "the one deny record is not in refused")
        #expect(core.distance(from: helper.lowerBound, to: match.range.lowerBound) < 400)
    }
}
