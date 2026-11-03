import Dispatch
import Foundation
import Synchronization
import Testing
import RVIsolation
@testable import RVMCP
@testable import RVMCPCustodianCore
@preconcurrency import XPC

@Suite("MCP custodian peer session")
struct CustodianPeerSessionTests {
    /// Records overlap between key operations and how many ran.
    final class KeyProbe: Sendable {
        private let state = Mutex((active: 0, maxActive: 0, macs: 0))
        var maxActive: Int { state.withLock { $0.maxActive } }
        var macs: Int { state.withLock { $0.macs } }

        func enter() {
            state.withLock {
                $0.active += 1
                $0.maxActive = max($0.maxActive, $0.active)
                $0.macs += 1
            }
        }
        func leave() { state.withLock { $0.active -= 1 } }
    }

    static func handler(probe: KeyProbe) -> CustodianRequestHandler {
        let signing = MCPApprovalSigning(
            status: { .enrolled },
            mac: { _, _, _ in
                probe.enter()
                defer { probe.leave() }
                Thread.sleep(forTimeInterval: 0.02)
                return "00"
            },
            verify: { _, _, _ in true })
        return CustodianRequestHandler(service: MCPCustodianKeyService(signing: signing))
    }

    static func message(_ frame: Data) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        CustodianXPCWire.set(frame, on: message)
        return message
    }

    static let macFrame = {
        try! JSONEncoder().encode(
            MCPCustodianRequest.mac(purpose: "grant", fields: ["a"], createIfMissing: true))
    }()
    static let helloFrame = { try! JSONEncoder().encode(MCPCustodianHello()) }()

    final class Counter: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func increment() { value.withLock { $0 += 1 } }
    }

    static func session(
        handler: CustodianRequestHandler, queue: DispatchQueue, begun: Counter, ended: DispatchSemaphore,
        role: TrustedRVComponentRole?
    ) -> CustodianPeerSession {
        CustodianPeerSession(
            handler: handler,
            watchdog: CustodianIdleWatchdog(),
            queue: queue,
            beginTransaction: { begun.increment() },
            endTransaction: { ended.signal() },
            capturePeerRole: { _, _ in role })
    }

    @Test func requestsFromEveryConnectionRunOneAtATimeAndBalanceTransactions() {
        let probe = KeyProbe()
        let handler = Self.handler(probe: probe)
        let queue = DispatchQueue(label: "test.custodian.requests")
        let begun = Counter()
        let ended = DispatchSemaphore(value: 0)
        let sessions = (0..<3).map { _ in
            Self.session(handler: handler, queue: queue, begun: begun, ended: ended, role: .cli)
        }
        for session in sessions { session.handle(Self.message(Self.helloFrame)) }
        for _ in 0..<4 {
            for session in sessions { session.handle(Self.message(Self.macFrame)) }
        }
        let total = 3 + 12
        for _ in 0..<total {
            #expect(ended.wait(timeout: .now() + 10) == .success)
        }
        #expect(probe.macs == 12)
        #expect(probe.maxActive == 1)
        #expect(begun.count == total)
    }

    @Test func handshakeGatingIsPerConnection() {
        let probe = KeyProbe()
        let handler = Self.handler(probe: probe)
        let queue = DispatchQueue(label: "test.custodian.gating")
        let begun = Counter()
        let ended = DispatchSemaphore(value: 0)
        let handshaken = Self.session(handler: handler, queue: queue, begun: begun, ended: ended, role: .cli)
        let stranger = Self.session(handler: handler, queue: queue, begun: begun, ended: ended, role: .cli)
        let notCLI = Self.session(handler: handler, queue: queue, begun: begun, ended: ended, role: .service)

        handshaken.handle(Self.message(Self.helloFrame))
        notCLI.handle(Self.message(Self.helloFrame))
        // No hello on this connection, and a non-CLI peer's failed hello.
        stranger.handle(Self.message(Self.macFrame))
        notCLI.handle(Self.message(Self.macFrame))
        handshaken.handle(Self.message(Self.macFrame))
        for _ in 0..<5 {
            #expect(ended.wait(timeout: .now() + 10) == .success)
        }
        #expect(probe.macs == 1)
    }
}
