import Foundation
import Synchronization
import Testing
import RVDomain
import RVIPC
@testable import RVGlance

/// The reader asks rvd for two things only, and the feed keeps its cursor,
/// reloads asks after a restart and backs off while rvd is down.
struct GlanceFeedTests {
    private let stream = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let restarted = UUID(uuidString: "99999999-2222-3333-4444-555555555555")!

    @Test func theReaderOnlyEverEncodesEventsAndPendingList() async throws {
        let wire = FakeWire { method in
            switch method {
            case .events: .events(EventsReply(stream: stream, cursor: 0, events: []))
            default: .pendingList(PendingListReply(generation: 1, items: []))
            }
        }
        let reader = GlanceReader(wire: wire)
        _ = await reader.events(EventsParams(after: 0, waitMs: 10))
        _ = await reader.pendingAsks()
        let names = wire.methods.map(Self.name)
        #expect(names == ["events", "pendingList"])
    }

    @Test func handshakeRequiredGreetsOnceAndAsksAgain() async {
        let wire = FakeWire(failFirstWithHandshake: true) { _ in
            .events(EventsReply(stream: stream, cursor: 4, events: []))
        }
        let poll = await GlanceReader(wire: wire).events(EventsParams(after: 0))
        #expect(poll == .events(EventsReply(stream: stream, cursor: 4, events: [])))
        #expect(wire.hellos == 1)
    }

    @Test func anOldRvdIsUnsupportedNotDown() async {
        let wire = FakeWire { _ in .error(.decodeFailed) }
        #expect(await GlanceReader(wire: wire).events(EventsParams()) == .unsupported)
    }

    @Test func aDeadWireIsDown() async {
        let wire = FakeWire(dead: true) { _ in .pendingList(PendingListReply(generation: 0, items: [])) }
        #expect(await GlanceReader(wire: wire).events(EventsParams()) == .down("rvd isn't answering"))
        #expect(wire.invalidations == 1)
    }

    @Test func theFeedReadsAsksThenPollsFromTheOldestEventAndKeepsTheCursor() async {
        let wire = FakeWire { method in
            switch method {
            case .pendingList:
                return .pendingList(PendingListReply(generation: 1, items: [Self.item("ask-1")]))
            case .events(let params) where params.after == 0:
                return .events(EventsReply(stream: stream, cursor: 7, events: [Self.denied(7)]))
            default:
                return .events(EventsReply(stream: stream, cursor: 8, events: [Self.denied(8)]))
            }
        }
        var feed = GlanceFeed(reader: GlanceReader(wire: wire), calendar: GlanceSamples.calendar, now: { GlanceSamples.now })
        #expect(await feed.step() == nil)
        #expect(await feed.step() == nil)
        let polls = wire.methods.compactMap { method -> EventsParams? in
            if case .events(let params) = method { return params }
            return nil
        }
        #expect(polls == [
            EventsParams(stream: nil, after: 0, waitMs: GlanceFeed.pollWaitMs),
            EventsParams(stream: stream, after: 7, waitMs: GlanceFeed.pollWaitMs),
        ])
        #expect(feed.state.pending == [ApprovalID(rawValue: "ask-1"): Self.item("ask-1").host])
        #expect(feed.state.today.stopped == 2)
        #expect(feed.state.glyph(at: GlanceSamples.now) == .needsYou)
    }

    @Test func aRestartedRvdReloadsTheAsks() async {
        let restarted = self.restarted
        let replies = Mutex([stream, restarted])
        let wire = FakeWire { method in
            if case .pendingList = method { return .pendingList(PendingListReply(generation: 1, items: [])) }
            let next = replies.withLock { $0.isEmpty ? restarted : $0.removeFirst() }
            return .events(EventsReply(stream: next, cursor: 1, resync: next == restarted, events: [Self.denied(1)]))
        }
        var feed = GlanceFeed(reader: GlanceReader(wire: wire), calendar: GlanceSamples.calendar, now: { GlanceSamples.now })
        _ = await feed.step()
        _ = await feed.step()
        _ = await feed.step()
        let pendingReads = wire.methods.filter { if case .pendingList = $0 { true } else { false } }.count
        #expect(pendingReads == 2)
    }

    @Test func aDownRvdBacksOffDoublingToTheCap() async {
        let wire = FakeWire(dead: true) { _ in .pendingList(PendingListReply(generation: 0, items: [])) }
        var feed = GlanceFeed(reader: GlanceReader(wire: wire), calendar: GlanceSamples.calendar, now: { GlanceSamples.now })
        var pauses: [Duration] = []
        for _ in 0..<6 { pauses.append(await feed.step() ?? .zero) }
        #expect(pauses == [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
        #expect(feed.state.link == .down("rvd isn't answering"))
        #expect(feed.state.glyph(at: GlanceSamples.now) == .notRunning)
    }

    @Test func anOldRvdKeepsShowingAsks() async {
        let wire = FakeWire { method in
            if case .pendingList = method {
                return .pendingList(PendingListReply(generation: 1, items: [Self.item("ask-9")]))
            }
            return .error(.unknownMethod)
        }
        var feed = GlanceFeed(reader: GlanceReader(wire: wire), calendar: GlanceSamples.calendar, now: { GlanceSamples.now })
        #expect(await feed.step() == GlanceFeed.pendingPollInterval)
        #expect(feed.state.link == .liveWithoutEvents)
        #expect(feed.state.glyph(at: GlanceSamples.now) == .needsYou)
    }

    @Test func thePostureIsReadEveryStep() async {
        let wire = FakeWire { method in
            if case .pendingList = method { return .pendingList(PendingListReply(generation: 1, items: [])) }
            return .events(EventsReply(stream: stream, cursor: 1, events: [Self.denied(1)]))
        }
        var feed = GlanceFeed(
            reader: GlanceReader(wire: wire), calendar: GlanceSamples.calendar,
            now: { GlanceSamples.now.addingTimeInterval(5) }, posture: { .watching([.codex]) })
        _ = await feed.step()
        #expect(feed.state.glyph(at: GlanceSamples.now.addingTimeInterval(5)) == .watching)
    }

    // MARK: - Helpers

    private static func name(_ method: IPCMethod) -> String {
        switch method {
        case .events: "events"
        case .pendingList: "pendingList"
        default: "other"
        }
    }

    static func item(_ id: String) -> PendingListItem {
        PendingListItem(
            id: ApprovalID(rawValue: id), host: .claude, folder: "rv", actionKind: "git push",
            fingerprint: ActionFingerprint(rawValue: "shell:git"),
            identity: ApprovalIdentity(session: SessionID(validating: "sess")!, agent: .claude))
    }

    static func denied(_ sequence: UInt64) -> LiveEvent {
        LiveEvent(
            sequence: sequence, atMs: Int64(GlanceSamples.now.timeIntervalSince1970 * 1000) - 60_000,
            payload: .decision(LiveDecision(
                verdict: .denied, host: .claude, tool: .bash, command: "git reset --hard", rule: "core.git:reset-hard")))
    }
}

/// Answers each request with `reply(method)`, recording what was asked.
final class FakeWire: GlanceWire, Sendable {
    private struct Log {
        var methods: [IPCMethod] = []
        var hellos = 0
        var invalidations = 0
        var handshakePending: Bool
    }

    private let log: Mutex<Log>
    private let dead: Bool
    private let reply: @Sendable (IPCMethod) -> IPCResult

    init(dead: Bool = false, failFirstWithHandshake: Bool = false, reply: @escaping @Sendable (IPCMethod) -> IPCResult) {
        self.dead = dead
        self.reply = reply
        self.log = Mutex(Log(handshakePending: failFirstWithHandshake))
    }

    var methods: [IPCMethod] { log.withLock { $0.methods } }
    var hellos: Int { log.withLock { $0.hellos } }
    var invalidations: Int { log.withLock { $0.invalidations } }

    func hello() async throws -> Bool {
        log.withLock {
            $0.hellos += 1
            $0.handshakePending = false
        }
        return true
    }

    func send(_ body: Data, timeoutMs _: Int) async throws -> Data {
        if dead { throw WireDown() }
        let request = try IPCJSON.decode(IPCRequest.self, from: body)
        let handshake = log.withLock { log -> Bool in
            log.methods.append(request.method)
            return log.handshakePending
        }
        let result = handshake ? IPCResult.error(.protocolSkew(.handshakeRequired)) : reply(request.method)
        return try IPCJSON.encode(IPCResponse(id: request.id, result: result))
    }

    func invalidate() {
        log.withLock { $0.invalidations += 1 }
    }
}

private struct WireDown: Error {}
