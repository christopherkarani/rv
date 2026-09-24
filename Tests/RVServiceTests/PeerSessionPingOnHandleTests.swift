#if canImport(XPC)
import Foundation
import Synchronization
import Testing
@preconcurrency import XPC
@testable import RVService

struct PeerSessionPingOnHandleTests {
    @Test func dictionaryHandlePingsInjectedWatchdog() async throws {
        let watchdog = IdleWatchdog(seconds: 300)
        let probe = TransactionProbe()
        let session = XPCPeerSession(
            runtime: try isolatedRuntime(),
            watchdog: watchdog,
            beginTransaction: { probe.begin() },
            endTransaction: { probe.end() }
        )
        let message = xpc_dictionary_create_empty()

        let task = try #require(session.handle(message))
        #expect(probe.beginCount == 1)
        await task.value

        #expect(await watchdog.pingCount == 1)
        #expect(probe.beginCount == 1)
        #expect(probe.endCount == 1)
    }

    @Test func dictionaryHandlePairsTransactionOnDecodeFailure() async throws {
        let watchdog = IdleWatchdog(seconds: 300)
        let probe = TransactionProbe()
        let session = XPCPeerSession(
            runtime: try isolatedRuntime(),
            watchdog: watchdog,
            beginTransaction: { probe.begin() },
            endTransaction: { probe.end() }
        )
        let message = xpc_dictionary_create_empty()
        XPCIPCWire.set(Data("not-json".utf8), on: message)

        let task = try #require(session.handle(message))
        await task.value

        #expect(await watchdog.pingCount == 1)
        #expect(probe.beginCount == 1)
        #expect(probe.endCount == 1)
    }

    @Test func nonDictionaryEventDoesNotPingOrBeginTransaction() async throws {
        let watchdog = IdleWatchdog(seconds: 300)
        let probe = TransactionProbe()
        let session = XPCPeerSession(
            runtime: try isolatedRuntime(),
            watchdog: watchdog,
            beginTransaction: { probe.begin() },
            endTransaction: { probe.end() }
        )

        #expect(session.handle(xpc_string_create("not-a-dictionary")) == nil)
        #expect(session.handle(xpc_int64_create(0)) == nil)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(await watchdog.pingCount == 0)
        #expect(probe.beginCount == 0)
        #expect(probe.endCount == 0)
    }

    @Test func stdinOverlayKeyRoundTripsMissingAndBytes() {
        let message = xpc_dictionary_create_empty()
        #expect(XPCIPCWire.stdin(from: message) == nil)

        let payload = Data(#"{"tool":"Bash"}"#.utf8)
        XPCIPCWire.setStdin(payload, on: message)
        #expect(XPCIPCWire.stdin(from: message) == payload)
    }

    @Test func twoDictionaryHandlesPingTheSameWatchdog() async throws {
        let watchdog = IdleWatchdog(seconds: 300)
        let probe = TransactionProbe()
        let session = XPCPeerSession(
            runtime: try isolatedRuntime(),
            watchdog: watchdog,
            beginTransaction: { probe.begin() },
            endTransaction: { probe.end() }
        )

        let first = try #require(session.handle(xpc_dictionary_create_empty()))
        await first.value
        let second = try #require(session.handle(xpc_dictionary_create_empty()))
        await second.value

        #expect(await watchdog.pingCount == 2)
        #expect(probe.beginCount == 2)
        #expect(probe.endCount == 2)
    }

    @Test func listenerSourceBeginsAndEndsXPCTransaction() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RVService/XPCListener.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("xpc_transaction_begin()"))
        #expect(text.contains("xpc_transaction_end()"))
    }
}

private final class TransactionProbe: Sendable {
    private let box = Mutex<State>(State())

    private struct State {
        var begins = 0
        var ends = 0
    }

    var beginCount: Int { box.withLock { $0.begins } }
    var endCount: Int { box.withLock { $0.ends } }

    func begin() { box.withLock { $0.begins += 1 } }
    func end() { box.withLock { $0.ends += 1 } }
}
#endif

