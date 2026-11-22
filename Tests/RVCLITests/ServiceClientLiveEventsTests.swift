import Foundation
import Testing
import RVIPC
@testable import RVCLI

/// `ServiceClient.liveEvents` against the answers a real rvd gives,
/// through the client's own send path (no hand-decoding).
struct ServiceClientLiveEventsTests {
    private let ack = HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok)
    private let stream = UUID()

    private func client(_ transport: ScriptedTransport) -> ServiceClient {
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

    @Test func noTransportFails() async {
        let client = ServiceClient(
            transport: nil,
            allowOnceDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-events-client-\(UUID().uuidString)", isDirectory: true),
            home: nil)
        #expect(await client.liveEvents(EventsParams()) == .failure(.noTransport))
    }
}
