#if canImport(Darwin)
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import RVMCP

/// Polls `condition` for up to `seconds`; never blocks in a wait call.
private func eventually(_ seconds: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while condition() == false {
        guard Date() < deadline else { return false }
        usleep(20_000)
    }
    return true
}

@Suite("rv mcp serve: shutdown on a signal")
struct MCPShutdownSignalTests {
    /// SIGURG is discarded by default, so sending it to this process ends
    /// nothing, and the test changes no disposition (`ignoring: false`).
    @Test(.timeLimit(.minutes(1)))
    func aHandledSignalReachesTheHandlerUntilCancelled() {
        let heard = Mutex<[Int32]>([])
        let signals = MCPShutdownSignals([SIGURG], ignoring: false) { number in heard.withLock { $0.append(number) } }
        #expect(kill(getpid(), SIGURG) == 0)
        #expect(eventually { heard.withLock { $0 } == [SIGURG] })
        signals.cancel()
        #expect(kill(getpid(), SIGURG) == 0)
        usleep(200_000)
        #expect(heard.withLock { $0 } == [SIGURG])
    }

    /// What the signal handler asks for: `run` stops every upstream and
    /// returns as if the client had closed its input.
    @Test(.timeLimit(.minutes(1)))
    func aShutdownRequestEndsRunAsTheClientLeavingWould() {
        let client = LineClient()
        let core = MCPGatewayCore(
            configuration: MCPConfiguration(servers: []), upstreams: [],
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced, recordForward: { _ in true })
        let runtime = MCPGatewayRuntime(
            core: core, connections: [],
            input: client.toGateway.fileHandleForReading.fileDescriptor,
            output: client.fromGateway.fileHandleForWriting.fileDescriptor,
            audit: { _ in }, log: { _ in })
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            runtime.run()
            done.signal()
        }
        runtime.requestShutdown()
        #expect(done.wait(timeout: .now() + 10) == .success)
        // The client reader thread ends with its input.
        try? client.toGateway.fileHandleForWriting.close()
    }
}
#endif
