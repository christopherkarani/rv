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
    ///
    /// Nothing here races the clock against the pool. Each poll needs a
    /// pool thread for a moment before it reaches its own thread, and when
    /// other suites hold the pool (CI starts ~1900 tests at once) that
    /// moment can be seconds long, for these tasks and for every other.
    /// So parking is awaited as an event, and the request is timed beside
    /// a control request on an idle client at the same moment, under the
    /// same load. Both failures this test guards against hang instead: a
    /// poll that blocked a pool thread lets at most core-count polls park,
    /// and a request queued behind a parked poll waits for a release that
    /// only comes after it. The time limit turns a hang into a failure.
    @Test(.timeLimit(.minutes(2)))
    func parkedPollsDoNotDelayOtherRequests() async throws {
        let gate = PollGate()
        let main = MainChannel(events: EventsChannel(gate: gate))
        let service = client(main)
        let idle = client(MainChannel(events: EventsChannel(gate: PollGate())))
        let count = max(16, ProcessInfo.processInfo.activeProcessorCount * 4)
        // Cleanup only, past the time limit: a failed run leaves no thread
        // parked.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 150)
            gate.release(count)
        }
        let polls = (0..<count).map { _ in
            Task { await service.liveEvents(EventsParams(waitMs: EventsParams.maxWaitMs)) }
        }
        await gate.parked(atLeast: count)
        #expect(gate.parked == count)

        async let control = timed { await idle.proposalStatus(operationID: UUID()) }
        async let request = timed { await service.proposalStatus(operationID: UUID()) }
        let (controlRun, run) = await (control, request)
        let other = run.result
        // Answered while every poll was still parked: none had returned.
        #expect(gate.returned == 0)
        // And not delayed by them: at most 2 s past the idle client's
        // request, well under the 5 s a poll waits, so a request held for
        // any part of a poll's wait fails here.
        let pollWait = Duration.milliseconds(EventsParams.maxWaitMs)
        #expect(run.took < controlRun.took + .seconds(2),
                "beside parked polls: \(run.took); idle client: \(controlRun.took)")
        #expect(run.took - controlRun.took < pollWait / 2)
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

/// Wall time of one async call.
private func timed<T: Sendable>(_ body: () async -> T) async -> (result: T, took: Duration) {
    let clock = ContinuousClock()
    let started = clock.now
    let result = await body()
    return (result, clock.now - started)
}

/// Releases parked polls; counts how many are parked and wakes a waiter
/// once enough are.
private final class PollGate: @unchecked Sendable {
    // DispatchSemaphore and Mutex are thread-safe; nothing else is stored.
    private let semaphore = DispatchSemaphore(value: 0)
    private struct State {
        var parked = 0
        var returned = 0
        var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?
    }
    private let state = Mutex(State())

    var parked: Int { state.withLock { $0.parked } }
    /// Polls that were released and returned.
    var returned: Int { state.withLock { $0.returned } }

    func park() {
        let ready = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.parked += 1
            guard let waiter = state.waiter, state.parked >= waiter.count else { return nil }
            state.waiter = nil
            return waiter.continuation
        }
        ready?.resume()
        semaphore.wait()
        state.withLock { $0.returned += 1 }
    }

    /// Suspends until `count` polls are parked, or the task is cancelled.
    func parked(atLeast count: Int) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { state -> Bool in
                    if state.parked >= count || Task.isCancelled { return true }
                    state.waiter = (count, continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
                defer { state.waiter = nil }
                return state.waiter?.continuation
            }
            waiting?.resume()
        }
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
