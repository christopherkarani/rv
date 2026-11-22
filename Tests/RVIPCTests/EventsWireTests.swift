import Foundation
import Testing
import RVDomain
@testable import RVIPC

/// `events` wire: golden frames, forward compatibility for new event
/// kinds, and the old-rvd answer a new client must read as "unsupported".
struct EventsWireTests {
    private let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let stream = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test func eventsRequestFrame_bytesMatchGolden() throws {
        let request = IPCRequest(id: id, method: .events(EventsParams(stream: stream, after: 7, waitMs: 5_000)))
        let data = try IPCJSON.encode(request)
        let golden =
            #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"events":{"after":7,"stream":"11111111-2222-3333-4444-555555555555","waitMs":5000}},"protocol":"rv.ipc.v1"}"#
        #expect(String(data: data, encoding: .utf8) == golden)
        #expect(try IPCJSON.decode(IPCRequest.self, from: data) == request)
    }

    @Test func firstCallOmitsTheCursor() throws {
        let data = try IPCJSON.encode(IPCRequest(id: id, method: .events(EventsParams())))
        #expect(String(data: data, encoding: .utf8)?.contains(#""events":{}"#) == true)
    }

    @Test func eventsReplyFrame_bytesMatchGoldenAndRoundTrips() throws {
        let decision = LiveDecision(
            verdict: .denied, host: .claude, tool: .bash, command: "git reset --hard", cwd: "~/proj",
            rule: "core.git:reset-hard", session: "abc-123")
        let ask = LiveAsk(item: PendingListItem(
            id: ApprovalID(rawValue: "ask-1"), host: .pi, folder: "ws", actionKind: "git push",
            fingerprint: ActionFingerprint(rawValue: "shell:git"),
            identity: ApprovalIdentity(session: SessionID(validating: "sess")!, agent: .pi)))
        let resolution = LiveResolution(id: ApprovalID(rawValue: "ask-1"), host: .pi, outcome: .allowOnce)
        let reply = EventsReply(stream: stream, cursor: 12, missed: 2, events: [
            LiveEvent(sequence: 10, atMs: 1_700_000_000_000, payload: .decision(decision)),
            LiveEvent(sequence: 11, atMs: 1_700_000_000_001, payload: .ask(ask)),
            LiveEvent(sequence: 12, atMs: 1_700_000_000_002, payload: .resolution(resolution)),
        ])
        let response = IPCResponse(id: id, result: .events(reply))
        let data = try IPCJSON.encode(response)
        let golden =
            #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"events":{"cursor":12,"events":[{"atMs":1700000000000,"decision":{"command":"git reset --hard","cwd":"~\/proj","host":"claude","rule":"core.git:reset-hard","session":"abc-123","timedOut":false,"tool":"Bash","verdict":"denied"},"kind":"decision","seq":10},{"ask":{"item":{"actionKind":"git push","fingerprint":"shell:git","folder":"ws","host":"pi","id":"ask-1","identity":{"agent":"pi","session":"sess"}}},"atMs":1700000000001,"kind":"ask","seq":11},{"atMs":1700000000002,"kind":"resolution","resolution":{"host":"pi","id":"ask-1","outcome":"allowOnce"},"seq":12}],"missed":2,"resync":false,"stream":"11111111-2222-3333-4444-555555555555"}}}"#
        #expect(String(data: data, encoding: .utf8) == golden)
        #expect(try IPCJSON.decode(IPCResponse.self, from: data) == response)
    }

    /// A newer rvd may publish kinds this client has never heard of, or a
    /// known kind with a value it cannot read. The reply still decodes; the
    /// event becomes `.unknown` and its sequence still moves the cursor.
    @Test func unknownKindsAndUnreadableBodiesDecodeAsUnknown() throws {
        let body = #"""
        {"stream":"11111111-2222-3333-4444-555555555555","cursor":3,"missed":0,"resync":false,"events":[
          {"seq":1,"atMs":5,"kind":"proposal","proposal":{"id":"p-1"}},
          {"seq":2,"atMs":6,"kind":"decision","decision":{"verdict":"paused","host":"claude","tool":"Bash","timedOut":false}},
          {"seq":3,"atMs":7,"kind":"resolution","resolution":{"id":"a","host":"pi","outcome":"deny"},"extra":true}
        ]}
        """#
        let reply = try IPCJSON.decode(EventsReply.self, from: Data(body.utf8))
        #expect(reply.events.map(\.sequence) == [1, 2, 3])
        #expect(reply.events[0].payload == .unknown(kind: "proposal"))
        #expect(reply.events[1].payload == .unknown(kind: "decision"))
        #expect(reply.events[2].payload == .resolution(LiveResolution(id: ApprovalID(rawValue: "a"), host: .pi, outcome: .deny)))
    }

    /// What an rvd from before `events` answers: it cannot decode the
    /// method key (`decodeFailed`). The client reads that as unsupported,
    /// not as a failure; any real reply or other error is not.
    @Test func oldDaemonAnswerReadsAsUnsupported() throws {
        let oldAnswer = #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"error":{"decodeFailed":true}}}"#
        let response = try IPCJSON.decode(IPCResponse.self, from: Data(oldAnswer.utf8))
        #expect(EventsCall.isUnsupported(response.result))
        #expect(EventsCall.isUnsupported(.error(.unknownMethod)))
        #expect(EventsCall.isUnsupported(.error(.authorizationDenied)) == false)
        #expect(EventsCall.isUnsupported(.events(EventsReply(stream: stream, cursor: 0, events: []))) == false)
        #expect(EventsCall.extract(.events(EventsReply(stream: stream, cursor: 4, events: [])))?.cursor == 4)
    }

    @Test func liveEventDateIsMillisecondsSince1970() {
        let event = LiveEvent(sequence: 1, at: Date(timeIntervalSince1970: 1.5), payload: .unknown(kind: "x"))
        #expect(event.atMs == 1_500)
    }

    /// A clock far off (or not a number) clamps instead of trapping.
    @Test func outOfRangeDatesClampToTheMillisecondRange() {
        #expect(LiveEvent.milliseconds(since1970: .nan) == 0)
        #expect(LiveEvent.milliseconds(since1970: .infinity) == .max)
        #expect(LiveEvent.milliseconds(since1970: -.infinity) == .min)
        #expect(LiveEvent.milliseconds(since1970: 1e300) == .max)
        #expect(LiveEvent.milliseconds(since1970: -1e300) == .min)
        #expect(LiveEvent.milliseconds(since1970: -1.5) == -1_500)
        #expect(LiveEvent(sequence: 1, at: .distantFuture, payload: .unknown(kind: "x")).atMs > 0)
    }
}
