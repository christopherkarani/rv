import Foundation
import Synchronization
import Testing
import RVIPC
@testable import RVCLI

/// `ServiceClient.liveEvents` against the answers a real rvd gives,
/// through the client's own send path (no hand-decoding).
struct ServiceClientLiveEventsTests {
    private let ack = HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok)
    private let stream = UUID()

    private func client(_ transport: any ServiceTransport) -> ServiceClient {
        ServiceClient(
            transport: transport,
            allowOnceDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-events-client-\(UUID().uuidString)", isDirectory: true),
            home: nil)
    }

    @Test func aCurrentDaemonAnswersWithEvents() async {
        let reply = EventsReply(stream: stream, cursor: 3, events: [])
        let transport = ScriptedTransport(ack: ack, responseResult: .events(reply))
        let result = await client(transport).liveEvents(EventsParams(waitMs: 1_000))
        #expect(result == .success(.events(reply)))
        // The transport waits past the poll's own wait.
        #expect(transport.lastSendTimeoutMs == 1_000 + ServiceClient.liveEventsReplyMarginMs)
    }

    /// An rvd from before `events` never decodes the request, so it cannot
    /// echo its id: `decodeFailed` arrives under a fresh one. That is
    /// "unsupported", not an identity mismatch or a failure.
    @Test func anOlderDaemonReadsAsUnsupported() async {
        let transport = ScriptedTransport(ack: ack, responseResult: .error(.decodeFailed), responseID: UUID())
        #expect(await client(transport).liveEvents(EventsParams()) == .success(.unsupported))
    }

    @Test func aDaemonThatRefusesTheMethodByNameReadsAsUnsupported() async {
        let transport = ScriptedTransport(ack: ack, responseResult: .error(.unknownMethod))
        #expect(await client(transport).liveEvents(EventsParams()) == .success(.unsupported))
    }

    /// Anything else stays a failure: a refusal, or a reply for another
    /// request.
    @Test func otherAnswersStayFailures() async {
        let denied = ScriptedTransport(ack: ack, responseResult: .error(.authorizationDenied))
        guard case .failure = await client(denied).liveEvents(EventsParams()) else {
            Issue.record("authorizationDenied must fail")
            return
        }
        let reply = EventsReply(stream: stream, cursor: 0, events: [])
        let crossed = ScriptedTransport(ack: ack, responseResult: .events(reply), responseID: UUID())
        #expect(await client(crossed).liveEvents(EventsParams()) == .failure(.transport("identityMismatch")))
    }

    /// A connection rvd has not greeted answers `handshakeRequired`: the
    /// poll says hello on its own channel and asks once more.
    @Test func anUngreetedChannelSaysHelloAndRetries() async {
        let reply = EventsReply(stream: stream, cursor: 2, events: [])
        let transport = ScriptedTransport(
            ack: ack, responseResults: [.error(.protocolSkew(.handshakeRequired)), .events(reply)])
        #expect(await client(transport).liveEvents(EventsParams()) == .success(.events(reply)))
        #expect(transport.helloCount == 1)
        #expect(transport.sendCount == 2)
    }

    /// An old rvd on a fresh connection: `handshakeRequired`, then after the
    /// hello `decodeFailed`, both under ids it made up.
    @Test func anOlderDaemonOnAFreshConnectionReadsAsUnsupported() async {
        let transport = ScriptedTransport(
            ack: ack, responseID: UUID(),
            responseResults: [.error(.protocolSkew(.handshakeRequired)), .error(.decodeFailed)])
        #expect(await client(transport).liveEvents(EventsParams()) == .success(.unsupported))
        #expect(transport.helloCount == 1)
    }

    /// Polls park on the events channel, blocking in a synchronous wait
    /// the way the Linux socket blocks in `recv`, many more than the pool
    /// has threads. A request on the same client still answers at once,
    /// over the main channel, and no poll ever went there.
    @Test func parkedPollsDoNotDelayOtherRequests() async throws {
        let gate = PollGate()
        let main = MainChannel(events: EventsChannel(gate: gate))
        let service = client(main)
        let count = max(16, ProcessInfo.processInfo.activeProcessorCount * 4)
        // Whatever happens, release the polls so a failure cannot hang.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 30)
            gate.release(count)
        }
        let polls = (0..<count).map { _ in
            Task { await service.liveEvents(EventsParams(waitMs: EventsParams.maxWaitMs)) }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(20)
        while gate.parked < count, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.parked == count)

        let started = clock.now
        let other = await service.proposalStatus(operationID: UUID())
        #expect(clock.now - started < .seconds(2))
        guard case .failure(.service(let reason)) = other else {
            Issue.record("the main channel must answer, got \(other)")
            return
        }
        #expect(reason == "authorizationDenied")
        #expect(main.eventsSent == 0)

        gate.release(count)
        for poll in polls {
            guard case .success(.events) = await poll.value else {
                Issue.record("a released poll must answer")
                continue
            }
        }
    }

    @Test func noTransportFails() async {
        let client = ServiceClient(
            transport: nil,
            allowOnceDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-events-client-\(UUID().uuidString)", isDirectory: true),
            home: nil)
        #expect(await client.liveEvents(EventsParams()) == .failure(.noTransport))
    }
}

/// Releases parked polls; counts how many are parked.
private final class PollGate: @unchecked Sendable {
    // DispatchSemaphore and Mutex are thread-safe; nothing else is stored.
    private let semaphore = DispatchSemaphore(value: 0)
    private let count = Mutex(0)

    var parked: Int { count.withLock { $0 } }

    func park() {
        count.withLock { $0 += 1 }
        semaphore.wait()
    }

    func release(_ polls: Int) {
        for _ in 0..<polls { semaphore.signal() }
    }
}

private let okAck = HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok)

/// The events channel: each poll blocks a thread in a synchronous wait
/// (as `UnixSocketServiceTransport` does in `recv`, through `BlockingIO`).
private struct EventsChannel: ServiceTransport {
    let gate: PollGate

    func hello(clientSemver: String) async throws -> HelloAckView { okAck }

    func send(_ body: Data) async throws -> Data {
        try await send(body, timeoutMs: 0)
    }

    func send(_ body: Data, timeoutMs: Int) async throws -> Data {
        let request = try IPCJSON.decode(IPCRequest.self, from: body)
        let gate = gate
        return try await BlockingIO.run {
            gate.park()
            return try IPCJSON.encode(IPCResponse(
                id: request.id, result: .events(EventsReply(stream: UUID(), cursor: 0, events: []))))
        }
    }

    func invalidate() {}
}

/// The client's main channel: answers every request at once and hands
/// `events` its own channel.
private final class MainChannel: ServiceTransport, Sendable {
    let events: EventsChannel
    private let eventsRequests = Mutex(0)

    init(events: EventsChannel) {
        self.events = events
    }

    var eventsSent: Int { eventsRequests.withLock { $0 } }

    func hello(clientSemver: String) async throws -> HelloAckView { okAck }

    func send(_ body: Data) async throws -> Data {
        let request = try IPCJSON.decode(IPCRequest.self, from: body)
        if case .events = request.method { eventsRequests.withLock { $0 += 1 } }
        return try IPCJSON.encode(IPCResponse(id: request.id, result: .error(.authorizationDenied)))
    }

    func send(_ body: Data, timeoutMs: Int) async throws -> Data {
        try await send(body)
    }

    func invalidate() {}

    func longPollChannel() -> any ServiceTransport { events }
}
