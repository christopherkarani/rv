#if os(macOS)
import Foundation
import Testing
@testable import RVMCP

@Suite("MCP custodian XPC client")
struct CustodianXPCClientTests {
    @Test func unreachableCustodianFailsClosedThroughXPC() {
        // No such Mach service is registered, so every exchange fails and
        // the signing seam must fail closed without any key material.
        let client = MCPCustodianXPCClient(
            serviceName: "dev.rv.mcp-custodian.test-absent",
            custodianExecutablePath: "/nonexistent/RVApprovals.app/Contents/MacOS/rv-mcp-custodian",
            helloTimeout: 2, requestTimeout: 2)
        #expect(client.send(.status) == nil)
        #expect(client.send(.mac(purpose: "grant", fields: ["a"], createIfMissing: true)) == nil)

        let signing = MCPApprovalSigning.custodian(transport: client.transport)
        #expect(signing.status() == .unavailable)
        #expect(signing.mac("grant", ["a"], true) == nil)
        #expect(signing.verify("00", "grant", ["a"]) == nil)
    }

    @Test func timeoutsAreBoundedPerOperation() {
        #expect(MCPCustodianXPCClient.timeout(for: .status, hello: 5, request: 120) == 5)
        #expect(MCPCustodianXPCClient.timeout(
            for: .mac(purpose: "grant", fields: [], createIfMissing: true), hello: 5, request: 120) == 120)
        #expect(MCPCustodianXPCClient.timeout(
            for: .verify(candidate: nil, purpose: "grant", fields: []), hello: 5, request: 120) == 120)
        #expect(MCPCustodianXPCClient.defaultHelloTimeout == 5)
        #expect(MCPCustodianXPCClient.defaultRequestTimeout == 120)
    }

    @Test func liveTransportTargetsTheInstalledBundle() {
        let path = MCPCustodianXPCClient.custodianExecutablePath(home: "/Users/example")
        #expect(path == "/Users/example/Applications/RVApprovals.app/Contents/MacOS/rv-mcp-custodian")
        #expect(MCPCustodianWire.machServiceName == "dev.rv.mcp-custodian")
    }
}
#endif
