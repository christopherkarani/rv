import Foundation
import Synchronization
import Testing
@testable import RVJudgePool

#if canImport(XPC)
import RVIsolation
@preconcurrency import XPC

/// In-memory workers: ready at once; each request answered with a verdict.
final class FakeWorkerSpawner: WorkerSpawning, Sendable {
    func spawn(
        slot: WorkerSlot, compute: WorkerCompute, key: ModelKey, output: @escaping @Sendable (WorkerOutput) -> Void
    ) throws -> any WorkerProcess {
        DispatchQueue.global().async {
            output(.frame(JudgePoolJSON.encode(WorkerEvent.ready(checkpoint: "fake"))!))
        }
        return FakeWorker(slot: slot, output: output)
    }
}

final class FakeWorker: WorkerProcess, Sendable {
    let slot: WorkerSlot
    let output: @Sendable (WorkerOutput) -> Void
    let exited = Mutex(false)

    init(slot: WorkerSlot, output: @escaping @Sendable (WorkerOutput) -> Void) {
        self.slot = slot
        self.output = output
    }

    func send(_ frame: Data) {
        var decoder = FrameStreamDecoder()
        guard let body = decoder.feed(frame).first,
              let request = JudgePoolJSON.decode(WorkerRequest.self, from: body) else { return }
        let verdict = Data(#"{"from":"\#(slot.rawValue)"}"#.utf8)
        DispatchQueue.global().async {
            self.output(.frame(JudgePoolJSON.encode(WorkerEvent.verdict(id: request.id, verdict: verdict))!))
        }
    }

    func kill() {
        let first = exited.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        if first { DispatchQueue.global().async { self.output(.exited(description: "killed")) } }
    }
}

/// A supervisor + XPC listener on anonymous connections, and the requests
/// it was sent (recorded as each arrives, before authorization decides).
final class XPCRig: Sendable {
    let supervisor: JudgePoolSupervisor
    let listener: JudgePoolXPCListener
    let discoveryEndpoint: JudgePoolHeld
    private let recorder = Recorder()

    final class Recorder: Sendable {
        let requests = Mutex<[JudgePoolRequest]>([])
    }

    /// `authorize` admits a message as `client` (true) or refuses it.
    init(client: JudgePoolClient = .service, authorize: @escaping @Sendable (xpc_object_t) -> Bool = { _ in true }) {
        let supervisor = JudgePoolSupervisor(spawner: FakeWorkerSpawner())
        let discovery = xpc_connection_create(nil, nil)
        let recorder = recorder
        let listener = JudgePoolXPCListener(
            supervisor: supervisor,
            authorize: { message in
                if let body = JudgePoolXPCBody.get(from: message),
                   let request = JudgePoolJSON.decode(JudgePoolRequest.self, from: body) {
                    recorder.requests.withLock { $0.append(request) }
                }
                return authorize(message) ? client : nil
            },
            discoveryListener: { discovery })
        listener.start()
        self.supervisor = supervisor
        self.listener = listener
        self.discoveryEndpoint = JudgePoolHeld(xpc_endpoint_create(discovery))
    }

    var seen: [JudgePoolRequest] { recorder.requests.withLock { $0 } }

    var hellos: Int { seen.filter { if case .hello = $0 { true } else { false } }.count }

    func stop() {
        listener.stop()
        supervisor.stop()
    }
}

/// Raw messages, for testing the listener without the client's handshake.
func rawConnection(_ endpoint: xpc_endpoint_t) -> xpc_connection_t {
    let connection = xpc_connection_create_from_endpoint(endpoint)
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_resume(connection)
    return connection
}

func rawSend(_ request: JudgePoolRequest, on connection: xpc_connection_t) -> (JudgePoolReply?, xpc_object_t?) {
    let message = xpc_dictionary_create_empty()
    JudgePoolXPCBody.set(JudgePoolJSON.encode(request)!, on: message)
    let reply = xpc_connection_send_message_with_reply_sync(connection, message)
    guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY, let body = JudgePoolXPCBody.get(from: reply) else {
        return (nil, nil)
    }
    return (JudgePoolJSON.decode(JudgePoolReply.self, from: body), reply)
}

@Suite("Judge pool XPC: handshake gating, client deadlines and re-warm", .serialized)
struct JudgePoolXPCTests {
    let key = ModelKey(engine: "ft", bundle: "/models/fake")
    let input = JudgeInput(command: "echo hi", contextLines: [])
    let hello = JudgePoolRequest.hello(protocolVersion: JudgePoolWire.protocolVersion)

    func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("the discovery connection only says hello; requests need a hello on the endpoint connection")
    func helloGating() throws {
        let rig = XPCRig()
        defer { rig.stop() }
        let discovery = rawConnection(rig.discoveryEndpoint.object)
        defer { xpc_connection_cancel(discovery) }
        #expect(rawSend(.status, on: discovery).0 == .refused, "no hello yet")
        let (ack, ackMessage) = rawSend(hello, on: discovery)
        #expect(ack == .helloAck(protocolVersion: JudgePoolWire.protocolVersion))
        #expect(rawSend(.status, on: discovery).0 == .refused, "discovery never serves requests")
        let endpoint = try #require(ackMessage.flatMap { xpc_dictionary_get_value($0, JudgePoolWire.xpcEndpointKey) })

        let requests = rawConnection(endpoint)
        defer { xpc_connection_cancel(requests) }
        #expect(rawSend(.status, on: requests).0 == .refused, "no hello on this connection yet")
        #expect(rawSend(.judge(key: key, input: input, budgetMilliseconds: 500), on: requests).0 == .refused)
        #expect(rawSend(.hello(protocolVersion: JudgePoolWire.protocolVersion + 1), on: requests).0 == .refused)
        #expect(rawSend(hello, on: requests).0 == .helloAck(protocolVersion: JudgePoolWire.protocolVersion))
        guard case .status? = rawSend(.status, on: requests).0 else {
            Issue.record("a connection that said hello is served")
            return
        }
    }

    @Test("an unauthorized peer is refused everything, hello included")
    func unauthorizedRefused() {
        let rig = XPCRig(authorize: { _ in false })
        defer { rig.stop() }
        let discovery = rawConnection(rig.discoveryEndpoint.object)
        defer { xpc_connection_cancel(discovery) }
        #expect(rawSend(hello, on: discovery).0 == .refused)
        let client = XPCJudgeClient(discover: { xpc_connection_create_from_endpoint(rig.discoveryEndpoint.object) },
                                    verify: { _ in true })
        #expect(client.judge(key: key, input: input, budget: .milliseconds(500)) == nil)
    }

    @Test("a reply that fails verification is never read")
    func unverifiedReplyIsNil() {
        let rig = XPCRig()
        defer { rig.stop() }
        let client = XPCJudgeClient(discover: { xpc_connection_create_from_endpoint(rig.discoveryEndpoint.object) },
                                    verify: { _ in false })
        #expect(client.judge(key: key, input: input, budget: .milliseconds(500)) == nil)
        #expect(client.status(timeout: .milliseconds(500)) == nil)
    }

    @Test("a verified supervisor answers through the client")
    func verdictThroughClient() async {
        let rig = XPCRig()
        defer { rig.stop() }
        rig.supervisor.warm(key: key)
        #expect(await eventually { rig.supervisor.status().workers.allSatisfy { $0.phase == "ready" } })
        let client = XPCJudgeClient(discover: { xpc_connection_create_from_endpoint(rig.discoveryEndpoint.object) },
                                    verify: { _ in true })
        guard case .verdict(_, let slot)? = client.judge(key: key, input: input, budget: .milliseconds(1000)) else {
            Issue.record("expected a verdict")
            return
        }
        #expect(slot == .primary)
    }

    @Test("the pool budget is what is left after connecting, not the caller's whole budget")
    func budgetAfterConnect() {
        let rig = XPCRig()
        defer { rig.stop() }
        let client = XPCJudgeClient(
            discover: {
                Thread.sleep(forTimeInterval: 0.3)
                return xpc_connection_create_from_endpoint(rig.discoveryEndpoint.object)
            },
            verify: { _ in true })
        _ = client.judge(key: key, input: input, budget: .milliseconds(1000))
        let budgets = rig.seen.compactMap { request -> Int? in
            if case .judge(_, _, let ms) = request { ms } else { nil }
        }
        #expect(budgets.count == 1)
        #expect((budgets.first ?? .max) <= 700, "300 ms went to connecting")
    }

    @Test("a timed-out request keeps the connection: the next request does not reconnect")
    func timeoutKeepsConnection() {
        // The supervisor is slower than the client's deadline (budget plus
        // transport slack) on every judged request.
        let rig = XPCRig { message in
            if let body = JudgePoolXPCBody.get(from: message),
               case .judge? = JudgePoolJSON.decode(JudgePoolRequest.self, from: body) {
                Thread.sleep(forTimeInterval: 0.5)
            }
            return true
        }
        defer { rig.stop() }
        let client = XPCJudgeClient(discover: { xpc_connection_create_from_endpoint(rig.discoveryEndpoint.object) },
                                    verify: { _ in true })
        #expect(client.judge(key: key, input: input, budget: .milliseconds(50)) == nil)
        #expect(client.judge(key: key, input: input, budget: .milliseconds(50)) == nil)
        #expect(rig.hellos == 2, "one discovery hello and one endpoint hello: a single connection")
    }

    @Test("a new connection warms the last model; a supervisor restart is re-warmed with no request")
    func rewarmsAfterRestart() async {
        let first = XPCRig()
        let current = Mutex(first.discoveryEndpoint)
        let client = XPCJudgeClient(
            discover: { xpc_connection_create_from_endpoint(current.withLock { $0 }.object) },
            verify: { _ in true },
            rewarmDelays: [.milliseconds(50), .milliseconds(100), .milliseconds(200)])
        _ = client.judge(key: key, input: input, budget: .milliseconds(500))
        #expect(await eventually { first.seen.contains(.warm(key: key)) }, "a fresh connection sends warm")

        // The supervisor goes away and a new one takes its place.
        let second = XPCRig()
        defer { second.stop() }
        current.withLock { $0 = second.discoveryEndpoint }
        first.stop()
        #expect(await eventually { second.seen.contains(.warm(key: key)) }, "re-warmed without a judged request")
        #expect(second.seen.allSatisfy { if case .judge = $0 { false } else { true } })
    }

    @Test("a warm that cannot connect retries until the supervisor is up")
    func warmRetriesUntilReachable() async {
        let down = XPCRig()
        down.stop()
        let current = Mutex(down.discoveryEndpoint)
        let client = XPCJudgeClient(
            discover: { xpc_connection_create_from_endpoint(current.withLock { $0 }.object) },
            verify: { _ in true },
            rewarmDelays: [.milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800)])
        client.warm(key: key)
        try? await Task.sleep(for: .milliseconds(50))
        let up = XPCRig()
        defer { up.stop() }
        current.withLock { $0 = up.discoveryEndpoint }
        #expect(await eventually { up.seen.contains(.warm(key: key)) }, "warmed once the supervisor answered")
    }

    @Test("a dropped connection (unverifiable reply) reconnects and re-warms with no request")
    func droppedConnectionRewarms() async {
        let rig = XPCRig()
        defer { rig.stop() }
        let rejectReplies = Mutex(false)
        let client = XPCJudgeClient(
            discover: { xpc_connection_create_from_endpoint(rig.discoveryEndpoint.object) },
            verify: { _ in !rejectReplies.withLock { $0 } },
            rewarmDelays: [.milliseconds(50), .milliseconds(100), .milliseconds(200)])
        _ = client.judge(key: key, input: input, budget: .milliseconds(500))
        #expect(await eventually { rig.seen.filter { $0 == .warm(key: key) }.count == 1 })
        #expect(rig.hellos == 2)

        rejectReplies.withLock { $0 = true }
        #expect(client.judge(key: key, input: input, budget: .milliseconds(500)) == nil)
        rejectReplies.withLock { $0 = false }
        #expect(await eventually { rig.seen.filter { $0 == .warm(key: key) }.count == 2 }, "re-warmed")
        #expect(rig.hellos == 4, "one reconnect")
        #expect(rig.seen.filter { if case .judge = $0 { true } else { false } }.count == 2)
    }
}

@Suite("Judge pool trust wiring")
struct JudgePoolTrustWiringTests {
    typealias Facts = JudgePoolTrust.PeerFacts

    @Test("the supervisor requires the service role, rvd requires the judge role")
    func roles() {
        let source = ProtectedPeerTrustConfiguration.HookTrustSource.manifest(.denyAll)
        for role in TrustedRVComponentRole.allCases {
            let facts: JudgePoolTrust.FactFinder = { _, _ in Facts(role: role, sameUser: true, matchesSibling: true) }
            #expect(JudgePoolTrust.authorizeClient(
                source: source, siblingClientPath: "/x/rvd", siblingEvaluatorPath: "/x/rv-hook-local", facts: facts)
                == (role == .service ? .service : nil))
            #expect(JudgePoolTrust.verifySupervisor(source: source, siblingSupervisorPath: "/x/rv-judge", facts: facts)
                == (role == .judge))
        }
    }

    @Test("sibling pin: checked against the given sibling path, needs same user and same code")
    func siblingPinWiring() {
        let seenPath = Mutex<String?>(nil)
        let facts: JudgePoolTrust.FactFinder = { _, path in
            seenPath.withLock { $0 = path }
            return Facts(role: nil, sameUser: true, matchesSibling: true)
        }
        #expect(JudgePoolTrust.verifySupervisor(source: .siblingPin, siblingSupervisorPath: "/x/rv-judge", facts: facts))
        #expect(seenPath.withLock { $0 } == "/x/rv-judge")
        #expect(!JudgePoolTrust.verifySupervisor(source: .siblingPin, siblingSupervisorPath: nil, facts: facts))
        #expect(JudgePoolTrust.authorizeClient(
            source: .siblingPin, siblingClientPath: "/x/rvd", siblingEvaluatorPath: nil) { _, _ in
            Facts(role: nil, sameUser: false, matchesSibling: true)
        } == nil)
        #expect(JudgePoolTrust.authorizeClient(
            source: .siblingPin, siblingClientPath: "/x/rvd", siblingEvaluatorPath: nil) { _, _ in nil } == nil)
        #expect(JudgePoolTrust.authorizeClient(
            source: .invalid, siblingClientPath: "/x/rvd", siblingEvaluatorPath: "/x/rv-hook-local", facts: facts)
            == nil)
    }

    @Test("manifest: the hook-local evaluator is a judge-only client; the service role still wins")
    func manifestEvaluator() {
        let source = ProtectedPeerTrustConfiguration.HookTrustSource.manifest(.denyAll)
        let decide = { (facts: Facts?) in
            JudgePoolTrust.authorizeClient(
                source: source, siblingClientPath: "/x/rvd", siblingEvaluatorPath: "/x/rv-hook-local"
            ) { _, _ in facts }
        }
        #expect(decide(Facts(role: nil, sameUser: true, matchesSibling: false, isHookEvaluator: true)) == .evaluator)
        #expect(decide(Facts(role: .service, sameUser: true, matchesSibling: false, isHookEvaluator: true)) == .service)
        #expect(decide(Facts(role: .cli, sameUser: true, matchesSibling: true, isHookEvaluator: false)) == nil)
        #expect(decide(nil) == nil)
        // rvd's side: an evaluator is never a supervisor.
        #expect(!JudgePoolTrust.verifySupervisor(source: source, siblingSupervisorPath: "/x/rv-judge") { _, _ in
            Facts(role: nil, sameUser: true, matchesSibling: true, isHookEvaluator: true)
        })
    }

    @Test("sibling pin: rvd's bytes are the service, rv-hook-local's bytes the evaluator, same user only")
    func siblingEvaluator() {
        let decide = { (sameUser: Bool, match: String, evaluatorPath: String?) in
            JudgePoolTrust.authorizeClient(
                source: .siblingPin, siblingClientPath: "/x/rvd", siblingEvaluatorPath: evaluatorPath
            ) { _, path in
                Facts(role: nil, sameUser: sameUser, matchesSibling: path == match)
            }
        }
        #expect(decide(true, "/x/rvd", "/x/rv-hook-local") == .service)
        #expect(decide(true, "/x/rv-hook-local", "/x/rv-hook-local") == .evaluator)
        #expect(decide(false, "/x/rv-hook-local", "/x/rv-hook-local") == nil)
        #expect(decide(true, "/x/other", "/x/rv-hook-local") == nil)
        #expect(decide(true, "/x/rv-hook-local", nil) == nil, "no evaluator path, no evaluator")
    }
}

@Suite("Judge pool XPC: the hook-local evaluator is a judge-only client", .serialized)
struct JudgePoolEvaluatorClientTests {
    let key = ModelKey(engine: "ft", bundle: "/models/fake")
    let input = JudgeInput(command: "echo hi", contextLines: [])
    let hello = JudgePoolRequest.hello(protocolVersion: JudgePoolWire.protocolVersion)

    @Test("an evaluator may say hello and ask for a verdict; warm and status are refused")
    func evaluatorRequests() throws {
        let rig = XPCRig(client: .evaluator)
        defer { rig.stop() }
        rig.supervisor.warm(key: key)
        let discovery = rawConnection(rig.discoveryEndpoint.object)
        defer { xpc_connection_cancel(discovery) }
        let (ack, ackMessage) = rawSend(hello, on: discovery)
        #expect(ack == .helloAck(protocolVersion: JudgePoolWire.protocolVersion))
        let endpoint = try #require(ackMessage.flatMap { xpc_dictionary_get_value($0, JudgePoolWire.xpcEndpointKey) })
        let requests = rawConnection(endpoint)
        defer { xpc_connection_cancel(requests) }
        #expect(rawSend(hello, on: requests).0 == .helloAck(protocolVersion: JudgePoolWire.protocolVersion))
        #expect(rawSend(.warm(key: key), on: requests).0 == .refused)
        #expect(rawSend(.status, on: requests).0 == .refused)
        guard case .outcome? = rawSend(.judge(key: key, input: input, budgetMilliseconds: 1000), on: requests).0 else {
            Issue.record("an evaluator's judge request is served")
            return
        }
    }

    @Test("a client that does not warm sends only hellos and judge requests, even across a restart")
    func nonWarmingClient() async {
        let first = XPCRig(client: .evaluator)
        let current = Mutex(first.discoveryEndpoint)
        let client = XPCJudgeClient(
            discover: { xpc_connection_create_from_endpoint(current.withLock { $0 }.object) },
            verify: { _ in true },
            rewarmDelays: [.milliseconds(20), .milliseconds(40)],
            warms: false)
        first.supervisor.warm(key: key)
        _ = client.judge(key: key, input: input, budget: .milliseconds(500))
        let second = XPCRig(client: .evaluator)
        defer { second.stop() }
        current.withLock { $0 = second.discoveryEndpoint }
        first.stop()
        try? await Task.sleep(for: .milliseconds(300))
        _ = client.judge(key: key, input: input, budget: .milliseconds(500))
        for rig in [first, second] {
            #expect(rig.seen.allSatisfy { request in
                switch request {
                case .hello, .judge: true
                case .warm, .status: false
                }
            })
        }
        #expect(second.seen.contains { if case .judge = $0 { true } else { false } }, "reconnects on demand")
    }
}
#endif

@Suite("Code hash cache")
struct CodeHashCacheTests {
    @Test("hashed once per file identity: a rewrite or a replacement hashes again")
    func cachesByIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-judge-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("rvd").path
        try Data("one".utf8).write(to: URL(fileURLWithPath: path))
        let calls = Mutex(0)
        let cache = CodeHashCache { file in
            calls.withLock { $0 += 1 }
            return FileManager.default.contents(atPath: file)
        }
        #expect(cache.hash(ofPath: path) == Data("one".utf8))
        #expect(cache.hash(ofPath: path) == Data("one".utf8))
        #expect(calls.withLock { $0 } == 1)
        // Replaced (new inode).
        let staged = directory.appendingPathComponent("rvd.new").path
        try Data("two".utf8).write(to: URL(fileURLWithPath: staged))
        #expect(rename(staged, path) == 0)
        #expect(cache.hash(ofPath: path) == Data("two".utf8))
        #expect(calls.withLock { $0 } == 2)
        // Rewritten in place: same inode, same size, new bytes.
        let inode = ExecutableIdentity(path: path).map(\.inode)
        let fd = open(path, O_WRONLY)
        #expect(fd >= 0)
        #expect(pwrite(fd, "six", 3, 0) == 3)
        close(fd)
        #expect(ExecutableIdentity(path: path).map(\.inode) == inode)
        #expect(cache.hash(ofPath: path) == Data("six".utf8))
        #expect(calls.withLock { $0 } == 3)
        #expect(cache.hash(ofPath: directory.appendingPathComponent("missing").path) == nil)
    }
}
