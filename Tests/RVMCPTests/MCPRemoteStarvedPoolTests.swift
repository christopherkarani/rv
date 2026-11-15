#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RVMCP

/// A busy process can hold every thread GCD gives its shared global queues
/// (a test run does). An `OperationQueue` delegate queue runs there by
/// default, so URLSession sent the request but its answer waited for a
/// free thread: the gateway saw a remote server that never replied.
@Suite("MCP remote upstream with GCD's shared pool exhausted", .enabled(if: python3Available))
struct MCPRemoteStarvedPoolTests {
    /// In the probe, so this process's pool is never exhausted: 256 items
    /// that never finish take every global-queue thread. The remote upstream
    /// and the secrets gateway's upstream transport still hear their
    /// answers; on a plain serial `OperationQueue` neither did.
    @Test(.timeLimit(.minutes(1)))
    func remoteAnswersArriveWhileTheSharedPoolIsExhausted() throws {
        let fixture = try RemoteFixture()
        let process = Process()
        process.executableURL = try mcpProbe()
        process.arguments = ["remote-starved", fixture.url("/mcp").absoluteString]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let requests = fixture.stop()
        var lines: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            lines[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        #expect(process.terminationReason == .exit && process.terminationStatus == 0, "\(text)")
        #expect(lines["upstream"].flatMap { Int($0) } != nil, "upstream answered: \(text); fixture: \(requests)")
        #expect(lines["live"]?.hasSuffix(" status 405") == true, "live answered: \(text)")
        #expect(lines["gateway"]?.hasSuffix(" status 405") == true, "gateway answered: \(text)")
        #expect(requests.contains("REQ POST /mcp initialize"), "\(requests)")
    }
}
#endif
