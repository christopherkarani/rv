import Foundation
import RVHistory
import Testing
@testable import RVCLI

/// `rv report` counts an MCP call once, though the gateway writes a
/// `stage=forward` record before the call and another when it ends.
@Suite("rv report MCP call counts")
struct ReportMCPCallCountTests {
    static func event(_ decision: AuditDecision, stage: String? = nil) -> AuditEvent {
        var detail = ["server": "github", "tool": "search"]
        if let stage { detail["stage"] = stage }
        return AuditEvent(
            time: Date(), kind: .mcpCall, decision: decision, subject: "github/search", source: "mcp-gateway",
            detail: detail)
    }

    @Test func aForwardedCallCountsOnce() {
        let counts = ReportRun.auditCounts([
            Self.event(.allowed, stage: "forward"), Self.event(.allowed),
            Self.event(.allowed, stage: "forward"), Self.event(.allowed),
            Self.event(.denied),
        ])
        #expect(counts["mcp.call"] == ["allowed": 2, "denied": 1])
        // Other kinds are counted as they are.
        let approval = AuditEvent(time: Date(), kind: .mcpApproval, decision: .allowed, subject: "x", source: "rv", detail: ["stage": "forward"])
        #expect(ReportRun.auditCounts([approval])["mcp.approval"] == ["allowed": 1])
    }
}
