import Foundation
import RVDomain
import Testing
@testable import RVEngine

@Suite("Runtime admission MCP normalize")
struct RuntimeAdmissionMCPNormalizeTests {
    @Test func mcpNeverNormalizesToAProposal() throws {
        let directory = try #require(WorkingDirectory(validating: "/tmp/rv-admission-mcp"))
        let subject = RuntimeAdmissionSubject(
            session: RuntimeSession(
                id: RuntimeSessionID(),
                workspaceSessionID: WorkspaceSessionID(),
                host: .opencode,
                workspace: directory,
                backend: .seatbelt,
                startedAt: Date(timeIntervalSince1970: 0),
                child: nil
            ),
            policyWorkspace: directory
        )
        // MCP dispatches route to the invoker after `submitMCP` admits
        // them; reaching the shell/http normalize fails closed.
        let result = normalizeRuntimeAdmission(
            subject: subject,
            action: .mcp(dispatch: MCPDispatchAction(
                address: "tools.demo.user.conn.read",
                argsDigest: MCPDispatchDigest.hex(of: "{}"),
                idempotencyKey: "key-1",
                argumentsJSON: "{}"
            ))
        )
        #expect(result == .failure(.failed))
    }
}
