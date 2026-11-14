#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RVMCP

/// `MCPGatewayRuntime.run` ignores SIGPIPE for the gateway itself. A plain
/// upstream it starts must not inherit that: a server that counts on
/// SIGPIPE to end it once its reader is gone would keep running.
@Suite("MCP gateway children's signals")
struct MCPGatewayChildSignalTests {
    @Test(.timeLimit(.minutes(1)))
    func aPlainUpstreamStartsWithSIGPIPEAtItsDefault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("disposition")
        let probe = try mcpProbe()
        let configuration = MCPConfiguration(servers: [MCPServerDefinition(name: "plain", command: probe.path)])
        let core = MCPGatewayCore(
            configuration: configuration, upstreams: configuration.servers.map { MCPGatewayCore.Upstream(definition: $0) },
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced, recordForward: { _ in true })
        let client = LineClient()
        let runtime = MCPGatewayRuntime(
            core: core,
            connections: [.process(MCPUpstreamLaunch(
                server: "plain", executable: probe.path, arguments: ["pipe-disposition", file.path], environment: [:]))],
            input: client.toGateway.fileHandleForReading.fileDescriptor,
            output: client.fromGateway.fileHandleForWriting.fileDescriptor,
            audit: { _ in }, log: { _ in })
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            runtime.run()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(20)
        var written: String?
        while Date() < deadline {
            if let data = FileManager.default.contents(atPath: file.path), data.isEmpty == false {
                written = String(decoding: data, as: UTF8.self)
                break
            }
            usleep(20_000)
        }
        try client.toGateway.fileHandleForWriting.close()
        #expect(done.wait(timeout: .now() + 10) == .success)
        // The gateway's own disposition, set by `run`, for contrast.
        var own = sigaction()
        sigaction(SIGPIPE, nil, &own)
        #expect(unsafeBitCast(own.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN as sig_t?, to: Int.self))
        #expect(written == "PIPE=default")
    }
}
#endif
