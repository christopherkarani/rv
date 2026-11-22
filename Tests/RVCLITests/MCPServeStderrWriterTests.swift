import Foundation
import Testing

/// What `rv mcp serve` writes to stderr goes through the gateway's one
/// stderr writer, which `MCPGatewayStderrTests` proves returns on a closed
/// stderr. `FileHandle.write` raised there instead, ending serve. Each call
/// site is checked in the source: none can be driven to a closed stderr from
/// inside the test process.
@Suite("rv mcp serve stderr writer")
struct MCPServeStderrWriterTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The text of `relative` from `start` up to the first `end` after it.
    private func slice(_ relative: String, from start: String, to end: String) throws -> Substring {
        let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
        let head = try #require(text.range(of: start), "\(relative): no \(start)")
        let tail = try #require(text.range(of: end, range: head.upperBound..<text.endIndex), "\(relative): no end after \(start)")
        return text[head.lowerBound..<tail.upperBound]
    }

    private func expectSafeWriter(_ code: Substring, _ site: String) {
        #expect(code.contains("MCPGatewayRuntime.writeStderrLine("), "\(site) does not use the stderr writer")
        #expect(code.contains("FileHandle") == false, "\(site) writes through FileHandle")
    }

    @Test func serveLogLinesUseTheWriter() throws {
        let code = try slice(
            "Sources/RVCLI/Commands/MCPCommand.swift",
            from: "let log: @Sendable (String) -> Void = {", to: "\n        }\n")
        expectSafeWriter(code, "serve's log")
    }

    @Test func aFailedAuditAppendUsesTheWriter() throws {
        let code = try slice(
            "Sources/RVCLI/Commands/MCPCommand.swift",
            from: "static func auditOrLog(", to: "\n    }\n")
        expectSafeWriter(code, "auditOrLog")
    }

    @Test func theSandboxNoticeDefaultsToTheWriter() throws {
        let code = try slice(
            "Sources/RVMCP/MCPSandbox.swift",
            from: "notice: @escaping @Sendable (String) -> Void =", to: "\n")
        expectSafeWriter(code, "the sandbox notice")
        let serve = try slice(
            "Sources/RVCLI/Commands/MCPCommand.swift",
            from: "sandbox: MCPSandbox.apply(", to: "placeholders:")
        #expect(serve.contains("notice:") == false, "serve overrides the sandbox notice")
    }

    @Test func theReasonServeStopsUsesTheWriter() throws {
        // Every stop reason is an `MCPServeRefusal` thrown out of `serve`;
        // `run` hands each one to `refuse`, which writes it.
        let run = try slice(
            "Sources/RVCLI/Commands/MCPCommand.swift",
            from: "try serve(home: home, environment: environment)", to: "\n    }\n")
        #expect(run.contains("catch let refusal as MCPServeRefusal"), "run does not catch serve's refusals")
        #expect(run.contains("try Self.refuse(refusal, ctx: ctx)"), "run does not hand refusals to refuse")
        let code = try slice(
            "Sources/RVCLI/Commands/MCPServeRefusal+CLI.swift",
            from: "let line = \"rv mcp serve: \\(refusal.log)\\n\"", to: "throw ExitCode(1)")
        expectSafeWriter(code, "serve's refuse")
        // The reason is written before the protocol answer is served.
        let written = try #require(code.range(of: "MCPGatewayRuntime.writeStderrLine(line)"))
        let answered = try #require(code.range(of: "MCPRefusalResponder.serve(refusal)"))
        #expect(written.lowerBound < answered.lowerBound, "serve answers the client before it writes the reason")
    }
}
