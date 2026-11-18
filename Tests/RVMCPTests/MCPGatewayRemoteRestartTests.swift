#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import RVMCP

private func eventually(_ timeout: TimeInterval = 90, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    await offThePool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }
}

/// Remote servers under the restart policy, and what the remote path bounds.
@Suite("MCPGatewayRuntime remote restarts", .enabled(if: python3Available))
struct MCPGatewayRemoteRestartTests {
    static func run(
        _ fixture: RemoteFixture, forwards: ForwardRecords = ForwardRecords(),
        writeBufferBytes: Int = MCPGatewayRuntime.writeBufferBytes,
        clientStallSeconds: TimeInterval = MCPGatewayRuntime.clientStallSeconds,
        remoteRequestLimit: Int? = nil, callTimeout: Int = MCPServerDefinition.defaultCallTimeoutSeconds
    ) -> GatewayRun {
        var remote = MCPServerDefinition(
            name: "remote", remote: MCPRemoteServer(url: fixture.url("/mcp")), tools: MCPToolPolicy(allow: ["*"]))
        remote.callTimeoutSeconds = callTimeout
        let core = MCPGatewayCore(
            configuration: MCPConfiguration(servers: [remote]), upstreams: [MCPGatewayCore.Upstream(definition: remote)],
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced,
            recordForward: { record in
                forwards.items.withLock { $0.append(record) }
                return true
            })
        return GatewayRun(
            core: core, connections: [.remote(MCPRemoteLaunch(server: "remote", url: fixture.url("/mcp")))],
            writeBufferBytes: writeBufferBytes, clientStallSeconds: clientStallSeconds,
            remoteRequestLimit: remoteRequestLimit)
    }

    static func message(_ text: String) throws -> JSONValue {
        try JSONValue.parse(Data(text.utf8))
    }

    static func cancel(_ id: Int) throws -> JSONValue {
        try Self.message(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(id)}}"#)
    }

    /// How many requests of `method` the fixture has logged.
    static func requests(_ fixture: RemoteFixture, _ method: String) -> Int {
        fixture.requests().components(separatedBy: "\n").filter { $0.contains("REQ POST /mcp \(method)") }.count
    }

    /// A remote has at most its limit of requests in flight, whatever they
    /// are. Past it nothing is sent: a request is refused (`send` says so),
    /// and a cancel is not posted but still closes the request it names,
    /// which frees its place.
    @Test(.timeLimit(.minutes(5)))
    func aRemoteHasAtMostItsLimitOfRequestsInFlight() async throws {
        let fixture = try RemoteFixture(["--hang-calls"])
        let delivered = RecordedMessages()
        let logged = Mutex<[String]>([])
        let remote = MCPRemoteUpstream(
            launch: MCPRemoteLaunch(server: "remote", url: fixture.url("/mcp")),
            deliver: { message in delivered.items.withLock { $0.append(message) } }, exited: {},
            log: { line in logged.withLock { $0.append(line) } }, requestLimit: 2)
        remote.start()
        #expect(remote.send(try Self.initialize(1)))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(1) } } })
        #expect(remote.send(try Self.message(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)))
        #expect(await eventually { remote.requestsInFlight == 0 }, "\(remote.requestsInFlight)")
        #expect(remote.send(try Self.message(Self.call(2))))
        #expect(remote.send(try Self.message(Self.call(3))))
        #expect(await eventually { Self.requests(fixture, "tools/call") == 2 }, "\(fixture.requests())")
        #expect(remote.requestsInFlight == 2)
        // At the limit: one more is not sent.
        #expect(remote.send(try Self.message(Self.call(4))) == false)
        #expect(remote.send(try Self.cancel(2)) == false)
        #expect(await eventually { fixture.requests().contains("CLOSED call 2") }, "\(fixture.requests())")
        #expect(await eventually { remote.requestsInFlight == 1 }, "\(remote.requestsInFlight)")
        #expect(Self.requests(fixture, "notifications/cancelled") == 0)
        #expect(logged.withLock { $0 }.contains { $0.contains("2 requests in flight") }, "\(logged.withLock { $0 })")
        // A freed place takes the next.
        #expect(remote.send(try Self.message(Self.call(5))))
        #expect(await eventually { Self.requests(fixture, "tools/call") == 3 }, "\(fixture.requests())")
        #expect(fixture.requests().contains("tools/call") && Self.requests(fixture, "tools/call") == 3)
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }

    /// A call that finds its remote full is not sent: the client is told it
    /// was not run, its audit record says so, and calls in flight go on.
    @Test(.timeLimit(.minutes(5)))
    func aCallPastTheRemotesRequestLimitIsNotRun() async throws {
        let fixture = try RemoteFixture(["--hang-calls"])
        let run = Self.run(fixture, remoteRequestLimit: 2)
        defer { run.stopNow() }
        #expect(await run.initialize())
        let runtime = run.runtime
        // rv's own initialize and initialized are over before the calls:
        // the server took initialized, and nothing is in flight.
        #expect(await eventually { fixture.requests().contains("ACCEPTED notifications/initialized") }, "\(fixture.requests())")
        #expect(await eventually { runtime.remoteRequestsInFlight("remote") == 0 })
        run.client.send(Self.call(2))
        run.client.send(Self.call(3))
        #expect(await eventually { Self.requests(fixture, "tools/call") == 2 }, "\(fixture.requests())")
        #expect(runtime.remoteRequestsInFlight("remote") == 2)
        run.client.send(Self.call(4))
        let refused = await MCPGatewayRestartRuntimeTests.reply(run, 4, timeout: 30)
        let message = refused?["error"]?["message"]?.stringValue ?? ""
        #expect(message.contains("was not run"), "\(String(describing: refused))")
        let audits = run.audits
        #expect(await eventually { audits.items.withLock { $0.contains { $0.outcome == .notRun } } })
        #expect(audits.items.withLock { $0.filter { $0.outcome == .notRun }.count } == 1)
        #expect(Self.requests(fixture, "tools/call") == 2)
        #expect(run.logs.text.contains("could not reach") == false, "\(run.logs.text)")
        #expect(await run.finish())
        _ = await offThePool { fixture.stop() }
    }

    /// A report of a request not sent that names an earlier launch of the
    /// remote ends nothing of the launch running now; one naming it does.
    @Test(.timeLimit(.minutes(5)))
    func aReportOfARequestNotSentForAnEarlierLaunchEndsNothing() async throws {
        let fixture = try RemoteFixture(["--hang-calls"])
        let run = Self.run(fixture)
        defer { run.stopNow() }
        #expect(await run.initialize())
        run.client.send(Self.call(2))
        #expect(await eventually { Self.requests(fixture, "tools/call") == 1 }, "\(fixture.requests())")
        let runtime = run.runtime
        let generation = try #require(runtime.remoteGeneration("remote"))
        for id in 1...200 { runtime.unsentOnQueue("remote", generation: generation - 1, id: .int(id)) }
        #expect(await run.client.next(timeout: 2) == nil, "a stale report ended a call")
        #expect(run.audits.items.withLock { $0.contains { $0.outcome == .notRun } } == false)
        for id in 1...200 { runtime.unsentOnQueue("remote", generation: generation, id: .int(id)) }
        let ended = await MCPGatewayRestartRuntimeTests.reply(run, 2, timeout: 30)
        #expect(ended?["error"]?["message"]?.stringValue?.contains("was not run") == true, "\(String(describing: ended))")
        #expect(await run.finish())
        _ = await offThePool { fixture.stop() }
    }

    /// A remote for the notification-bound tests: started, initialized,
    /// and with nothing in flight.
    static func boundRemote(
        _ fixture: RemoteFixture, lifetime: TimeInterval = 30, afterHead: TimeInterval = 1, requestLimit: Int = 4,
        authorizer: MCPRemoteAuthorizer? = nil, exits: PlanCount? = nil, logged: LoggedLines? = nil
    ) async throws -> MCPRemoteUpstream {
        let delivered = RecordedMessages()
        let remote = MCPRemoteUpstream(
            launch: MCPRemoteLaunch(server: "remote", url: fixture.url("/mcp")), authorizer: authorizer,
            deliver: { message in delivered.items.withLock { $0.append(message) } },
            exited: { exits?.value.withLock { $0 += 1 } }, log: { line in logged?.items.withLock { $0.append(line) } },
            requestLimit: requestLimit, notificationLifetime: lifetime, notificationAfterHead: afterHead)
        remote.start()
        remote.send(try Self.initialize(1))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(1) } } })
        remote.send(try Self.message(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        #expect(await eventually { fixture.requests().contains("ACCEPTED notifications/initialized") }, "\(fixture.requests())")
        #expect(await eventually { remote.requestsInFlight == 0 }, "\(remote.requestsInFlight)")
        return remote
    }

    /// Seconds until `remote` has nothing in flight (nil past `limit`).
    static func secondsUntilIdle(_ remote: MCPRemoteUpstream, limit: TimeInterval = 15) async -> TimeInterval? {
        let started = Date()
        guard await eventually(limit, { remote.requestsInFlight == 0 }) else { return nil }
        return Date().timeIntervalSince(started)
    }

    /// A notification whose server goes on after a 202 head is let go
    /// once its bound after the head runs out (1 s here, 5 s by default),
    /// not at the head; each frees its place, so cancels to such a server
    /// never walk the count up to the limit.
    @Test(.timeLimit(.minutes(5)))
    func aNotificationStreamedAfterItsHeadIsCutAfterItsBound() async throws {
        let fixture = try RemoteFixture(["--stream-notifications"])
        let logged = LoggedLines()
        let remote = try await Self.boundRemote(fixture, logged: logged)
        for id in 100..<106 {
            #expect(remote.send(try Self.cancel(id)), "cancel \(id) was refused: \(remote.requestsInFlight) in flight")
            let waited = await Self.secondsUntilIdle(remote)
            #expect(waited != nil, "cancel \(id) is still in flight")
            #expect((waited ?? 0) >= 0.8, "cut before its bound: \(String(describing: waited))")
        }
        #expect(await eventually(30) {
            fixture.requests().components(separatedBy: "CLOSED notification notifications/cancelled").count == 7
        }, "\(fixture.requests())")
        let bounded = logged.items.withLock { lines in lines.filter { line in line.contains("past its bound") }.count }
        #expect(bounded == 6, "\(logged.items.withLock { $0 })")
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }

    /// A reply rv posts (to a request of the server's) has the same bound.
    @Test(.timeLimit(.minutes(5)))
    func aReplyStreamedAfterItsHeadIsCutAfterItsBound() async throws {
        let fixture = try RemoteFixture(["--stream-notifications"])
        let remote = try await Self.boundRemote(fixture)
        #expect(remote.send(try Self.message(#"{"jsonrpc":"2.0","id":7,"result":{}}"#)))
        let waited = await Self.secondsUntilIdle(remote)
        #expect(waited != nil && (waited ?? 0) >= 0.8, "\(String(describing: waited))")
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }

    /// A notification whose response head never finishes is let go when
    /// its lifetime from sending runs out (2 s here, 30 s by default),
    /// though bytes keep coming.
    @Test(.timeLimit(.minutes(5)))
    func aNotificationWhoseHeadDripsIsCutByItsLifetime() async throws {
        let fixture = try RemoteFixture(["--drip-notification-heads"])
        let remote = try await Self.boundRemote(fixture, lifetime: 2)
        #expect(remote.send(try Self.cancel(100)))
        let waited = await Self.secondsUntilIdle(remote)
        #expect(waited != nil && (waited ?? 0) >= 1.5, "\(String(describing: waited))")
        #expect(await eventually(30) { fixture.requests().contains("CLOSED notification notifications/cancelled") }, "\(fixture.requests()) live post sessions: \(remote.postSessionsLive)")
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }

    /// A normal 202 is never cut: it ends by itself, and nothing is closed.
    @Test(.timeLimit(.minutes(5)))
    func aNormalNotificationIsNeverCut() async throws {
        let fixture = try RemoteFixture()
        let logged = LoggedLines()
        let remote = try await Self.boundRemote(fixture, logged: logged)
        #expect(remote.send(try Self.cancel(100)))
        #expect(await eventually(5) { remote.requestsInFlight == 0 })
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let bounded = logged.items.withLock { lines in lines.contains { line in line.contains("past its bound") } }
        #expect(bounded == false, "\(logged.items.withLock { $0 })")
        #expect(fixture.requests().contains("ACCEPTED notifications/cancelled"))
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }

    /// A notification answered 401 is refreshed and sent again once,
    /// whether the 401 ends by itself or its body never ends and the bound
    /// cuts it.
    @Test(.timeLimit(.minutes(5)), arguments: [false, true])
    func aNotificationAnswered401IsSentAgainOnce(endless: Bool) async throws {
        let fixture = try RemoteFixture(["--token", "good-token"] + (endless ? ["--endless-refusals"] : []))
        let token = Mutex("good-token")
        let authorizer = MCPRemoteAuthorizer(
            token: { token.withLock { $0 } },
            refresh: { _ in
                token.withLock { $0 = "good-token" }
                return true
            })
        let remote = try await Self.boundRemote(fixture, authorizer: authorizer)
        token.withLock { $0 = "stale-token" }
        #expect(remote.send(try Self.cancel(100)))
        #expect(await eventually(15) { fixture.requests().contains("ACCEPTED notifications/cancelled") }, "\(fixture.requests())")
        #expect(await eventually(15) { remote.requestsInFlight == 0 })
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let lines = fixture.requests().components(separatedBy: "\n")
        #expect(lines.filter { $0.contains("ACCEPTED notifications/cancelled") }.count == 1, "\(fixture.requests())")
        #expect(lines.filter { $0.contains("-> 401") }.count == 1, "\(fixture.requests())")
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }

    /// A notification answered 404 ends the session, once, whether the 404
    /// ends by itself or the bound cuts its endless body.
    @Test(.timeLimit(.minutes(5)), arguments: [false, true])
    func aNotificationAnswered404EndsTheSessionOnce(endless: Bool) async throws {
        let fixture = try RemoteFixture(endless ? ["--endless-refusals"] : [])
        let exits = PlanCount()
        let remote = try await Self.boundRemote(fixture, exits: exits)
        #expect(await Self.post(fixture.url("/expire-sessions")) == 200)
        #expect(remote.send(try Self.cancel(100)))
        #expect(await eventually(15) { exits.value.withLock { $0 } == 1 })
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(exits.value.withLock { $0 } == 1)
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }

    /// rv's own ping is not held back by the request limit: a remote that
    /// is full can still be judged (there is one ping at a time).
    @Test(.timeLimit(.minutes(5)))
    func aPingGoesOutAtTheRequestLimit() async throws {
        let fixture = try RemoteFixture(["--hang-calls"])
        let remote = try await Self.boundRemote(fixture, requestLimit: 2)
        #expect(remote.send(try Self.message(Self.call(2))))
        #expect(remote.send(try Self.message(Self.call(3))))
        #expect(await eventually { Self.requests(fixture, "tools/call") == 2 }, "\(fixture.requests())")
        #expect(remote.send(try Self.message(Self.call(4))) == false)
        #expect(remote.send(try Self.message(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#)))
        #expect(await eventually { Self.requests(fixture, "ping") == 1 }, "\(fixture.requests())")
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }

    /// A remote at its request limit whose call times out is pinged: one
    /// that answers is left running, one that does not is stopped and
    /// started again.
    @Test(.timeLimit(.minutes(5)), arguments: [false, true])
    func aFullRemoteIsStillJudgedByItsPing(deaf: Bool) async throws {
        let fixture = try RemoteFixture(["--hang-calls"] + (deaf ? ["--deaf-pings"] : []))
        let run = Self.run(fixture, remoteRequestLimit: 2, callTimeout: 2)
        defer { run.stopNow() }
        #expect(await run.initialize())
        #expect(await eventually { fixture.requests().contains("ACCEPTED notifications/initialized") }, "\(fixture.requests())")
        run.client.send(Self.call(2))
        run.client.send(Self.call(3))
        #expect(await eventually { Self.requests(fixture, "ping") >= 1 }, "\(fixture.requests())")
        let logs = run.logs
        if deaf {
            #expect(await eventually(60) { logs.text.contains("did not answer a ping") }, "\(logs.text)")
            #expect(await eventually(60) { Self.initializes(fixture) == 2 }, "\(fixture.requests())")
        } else {
            try await Task.sleep(nanoseconds: 14_000_000_000)
            #expect(logs.text.contains("did not answer a ping") == false, "\(logs.text)")
            #expect(Self.initializes(fixture) == 1)
        }
        #expect(await run.finish())
        _ = await offThePool { fixture.stop() }
    }

    /// A read put back after `stop()` keeps the session `stop()` took out,
    /// so it is not invalidated a second time. This guards only on Linux,
    /// where each POST has a session of its own and the count of live ones
    /// must never go below 0; on macOS there are no such sessions, and the
    /// count stays 0 either way.
    @Test(.timeLimit(.minutes(5)))
    func aStopDuringAReadInvalidatesItsSessionOnce() async throws {
        let fixture = try RemoteFixture(["--hang-calls", "--hang-notes"])
        let box = Mutex<MCPRemoteUpstream?>(nil)
        let stopped = Mutex(false)
        let delivered = RecordedMessages()
        let remote = MCPRemoteUpstream(
            launch: MCPRemoteLaunch(server: "remote", url: fixture.url("/mcp")),
            deliver: { message in delivered.items.withLock { $0.append(message) } }, exited: {}, log: { _ in },
            whileReceiving: { request in
                guard request["id"] == .int(2), stopped.withLock({ was in defer { was = true }; return was == false }) else {
                    return
                }
                box.withLock { $0 }?.stop()
            })
        box.withLock { $0 = remote }
        defer { box.withLock { $0 = nil } }
        remote.start()
        remote.send(try Self.initialize(1))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(1) } } })
        remote.send(try Self.message(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        remote.send(try Self.message(Self.call(2)))
        #expect(await eventually { stopped.withLock { $0 } })
        #expect(await eventually { remote.postSessionsLive == 0 }, "\(remote.postSessionsLive)")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(remote.postSessionsLive == 0, "a session was invalidated twice: \(remote.postSessionsLive)")
        _ = await offThePool { fixture.stop() }
    }

    /// An event-stream reply is closed once its answer is in: a server that
    /// answers and then holds the stream open holds no connection of rv's.
    @Test(.timeLimit(.minutes(5)))
    func anEventStreamReplyIsClosedOnceItIsAnswered() async throws {
        let fixture = try RemoteFixture(["--hold-replies"])
        let delivered = RecordedMessages()
        let exits = Mutex(0)
        let remote = MCPRemoteUpstream(
            launch: MCPRemoteLaunch(server: "remote", url: fixture.url("/mcp")),
            deliver: { message in delivered.items.withLock { $0.append(message) } },
            exited: { exits.withLock { $0 += 1 } }, log: { _ in })
        remote.start()
        remote.send(try Self.initialize(1))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(1) } } })
        remote.send(try Self.message(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        remote.send(try Self.message(Self.call(2)))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(2) } } })
        #expect(await eventually(30) { fixture.requests().contains("CLOSED reply 2") }, "\(fixture.requests())")
        #expect(exits.withLock { $0 } == 0)
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }

    static func call(_ id: Int, text: String = "x") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"echo","arguments":{"text":"\#(text)"}}}"#
    }

    static func call(_ id: Int, arguments: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"echo","arguments":\#(arguments)}}"#
    }

    static func initialize(_ id: Int) throws -> JSONValue {
        try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#.utf8))
    }

    /// The client's next line answering `id`, read straight from its pipe.
    /// A line over 1 MiB (an answer the test does not look at) is skipped
    /// unparsed: `LineClient` would scan it again on every read.
    static func skim(_ run: GatewayRun, _ id: Int, timeout: TimeInterval = 90) async -> JSONValue? {
        let fd = run.client.fromGateway.fileHandleForReading.fileDescriptor
        return await offThePool {
            var line = Data()
            var skipping = false
            var chunk = [UInt8](repeating: 0, count: 1 << 20)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 200) > 0 else { continue }
                let n = read(fd, &chunk, chunk.count)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return nil }
                var start = 0
                for index in 0..<n where chunk[index] == 0x0A {
                    if skipping == false {
                        line.append(contentsOf: chunk[start..<index])
                        if let message = try? JSONValue.parse(line), message["id"] == .int(id) { return message }
                    }
                    line.removeAll()
                    skipping = false
                    start = index + 1
                }
                if skipping == false {
                    line.append(contentsOf: chunk[start..<n])
                    if line.count > 1 << 20 {
                        skipping = true
                        line.removeAll()
                    }
                }
            }
            return nil
        }
    }

    static func ran(_ record: MCPCallRecord) -> Bool {
        if case .ran = record.outcome { true } else { false }
    }

    /// The status of an empty POST to `url`, waited for off the pool.
    static func post(_ url: URL) async -> Int {
        await offThePool {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            let status = Mutex(0)
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { _, response, _ in
                status.withLock { $0 = (response as? HTTPURLResponse)?.statusCode ?? 0 }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 60)
            return status.withLock { $0 }
        }
    }

    static func initializes(_ fixture: RemoteFixture) -> Int {
        fixture.requests().components(separatedBy: "REQ POST /mcp initialize").count - 1
    }

    /// A session the server ends (HTTP 404) is the server going away: the
    /// call on it ends once, saying it may have run, and rv starts a new
    /// session after its delay, which serves the next call.
    @Test(.timeLimit(.minutes(5)))
    func aRemoteThatEndsItsSessionIsConnectedAgain() async throws {
        let fixture = try RemoteFixture()
        let run = Self.run(fixture)
        defer { run.stopNow() }
        #expect(await run.initialize())
        // Nothing but the call may meet the ended session: rv's own
        // `notifications/initialized` POST runs beside it, and a 404 on that
        // would end the session first (the call then refused as restarting).
        run.client.send(Self.call(2))
        let served = await MCPGatewayRestartRuntimeTests.reply(run, 2)
        #expect(served?["result"] != nil, "\(String(describing: served))")
        #expect(await eventually { fixture.requests().contains("ACCEPTED notifications/initialized") }, "\(fixture.requests())")
        #expect(await Self.post(fixture.url("/expire-sessions")) == 200)
        run.client.send(Self.call(3))
        let ended = await MCPGatewayRestartRuntimeTests.reply(run, 3)
        #expect(ended?["error"]?["message"]?.stringValue?.contains("may have run") == true, "\(String(describing: ended))")
        let answer = await MCPGatewayRestartRuntimeTests.echoes(run, from: 4)
        #expect(answer?["result"] != nil, "\(run.logs.text)")
        #expect(Self.initializes(fixture) == 2, "\(fixture.requests())")
        #expect(await run.finish())
        _ = await offThePool { fixture.stop() }
    }

    /// A connection that fails under a call is not the server's answer: the
    /// call is recorded as interrupted (it may have run), never as run, and
    /// the server is connected again. It ends as soon as its connection
    /// fails, not at its deadline, and the call is never sent again: on
    /// Linux libcurl sends a request again, without its body, when a reused
    /// connection drops before an answer, so no request POST goes out on a
    /// reused connection there.
    @Test(.timeLimit(.minutes(5)))
    func aCallWhoseConnectionFailsMayHaveRunAndTheServerComesBack() async throws {
        let fixture = try RemoteFixture(["--reset-calls", "--log-connections"])
        let run = Self.run(fixture)
        defer { run.stopNow() }
        #expect(await run.initialize())
        run.client.send(Self.call(2))
        // Far inside the call's 300 s limit.
        let failed = await MCPGatewayRestartRuntimeTests.reply(run, 2, timeout: 30)
        #expect(failed?["error"]?["message"]?.stringValue?.contains("may have run") == true, "\(String(describing: failed)) \(fixture.requests())")
        let audits = run.audits
        #expect(await eventually { audits.items.withLock { $0.contains { $0.tool == "echo" } } })
        #expect(audits.items.withLock { $0.filter { $0.tool == "echo" }.map(\.outcome) } == [.interrupted(grant: nil)])
        let logs = run.logs
        #expect(await eventually { logs.text.contains("MCP server remote is back") }, "\(logs.text)")
        #expect(await run.finish())
        let requests = await offThePool { fixture.stop() }
        let lines = requests.components(separatedBy: "\n")
        let entered = lines.filter { $0.contains("ENTER POST /mcp ") }
        // The call reached the server once, and every POST that arrived
        // carried its request: none came again without its body.
        #expect(lines.filter { $0.contains("REQ POST /mcp tools/call") }.count == 1, "\(requests)")
        #expect(entered.count == lines.filter { $0.contains("REQ POST /mcp ") }.count, "\(requests)")
        #if canImport(FoundationNetworking)
        let ports = entered.compactMap { $0.components(separatedBy: "port=").last }
        #expect(Set(ports).count == ports.count, "a POST went out on a reused connection: \(requests)")
        #endif
    }

    /// What a remote has not taken counts against its bound until its
    /// request body has gone out. Past the bound it is stopped, the core
    /// hears at once, and the next call is refused without being forwarded.
    @Test(.timeLimit(.minutes(5)))
    func aRemoteThatTakesNothingIsStoppedPastItsBound() async throws {
        let fixture = try RemoteFixture(["--deaf-over", "\(1 << 20)"])
        let forwards = ForwardRecords()
        let run = Self.run(fixture, forwards: forwards, writeBufferBytes: 256 << 10)
        defer { run.stopNow() }
        #expect(await run.initialize())
        // Far more than the connection's buffers hold, so it never all goes out.
        let pad = String(repeating: "p", count: 32 << 20)
        run.client.send(Self.call(2, text: pad))
        #expect(await eventually { fixture.requests().contains("DEAF POST") })
        run.client.send(Self.call(3))
        run.client.send(Self.call(4))
        for id in [2, 3] {
            let stopped = await MCPGatewayRestartRuntimeTests.reply(run, id)
            #expect(stopped?["error"]?["message"]?.stringValue?.contains("may have run") == true, "\(String(describing: stopped))")
        }
        let refused = await MCPGatewayRestartRuntimeTests.reply(run, 4)
        let message = refused?["error"]?["message"]?.stringValue ?? ""
        #expect(message.contains("rv is restarting it"), "\(message)")
        #expect(forwards.items.withLock { $0.count } == 2)
        let logs = run.logs
        #expect(await eventually { logs.text.contains("is not reading its input") }, "\(logs.text)")
        #expect(await run.finish())
        _ = await offThePool { fixture.stop() }
    }

    /// A request counts against its remote's bound only until its body has
    /// gone out: calls the server took and has not answered stop nothing,
    /// however many there are.
    @Test(.timeLimit(.minutes(5)))
    func requestsTheServerTookNoLongerCountAgainstItsBound() async throws {
        let fixture = try RemoteFixture(["--hang-calls"])
        let run = Self.run(fixture, writeBufferBytes: 256 << 10)
        defer { run.stopNow() }
        #expect(await run.initialize())
        let pad = String(repeating: "p", count: 100 << 10)
        for (index, id) in [2, 3, 4].enumerated() {
            run.client.send(Self.call(id, text: pad))
            #expect(await eventually {
                fixture.requests().components(separatedBy: "REQ POST /mcp tools/call").count - 1 == index + 1
            }, "\(fixture.requests())")
            let runtime = run.runtime
            try #require(await eventually(60) { runtime.remoteBytesInFlight("remote") == 0 },
                "\(String(describing: runtime.remoteBytesInFlight("remote"))) \(run.logs.text)")
        }
        #expect(run.logs.text.contains("is not reading its input") == false, "\(run.logs.text)")
        #expect(await run.finish())
        _ = await offThePool { fixture.stop() }
    }

    /// A remote whose answers come faster than the client takes them is
    /// stopped once more than its bound waits behind what the client has
    /// not taken: the call it was answering ends saying it may have run,
    /// and it is started again. The same on every system: its connection
    /// is never paused.
    @Test(.timeLimit(.minutes(5)))
    func aRemoteFasterThanTheClientIsStoppedPastItsBound() async throws {
        let fixture = try RemoteFixture()
        let run = Self.run(fixture, writeBufferBytes: 256 << 10, clientStallSeconds: 3600)
        defer { run.stopNow() }
        #expect(await run.initialize())
        // Not taken yet by the client: what it holds for the client fills
        // the remote's reader backlog.
        run.client.send(Self.call(2, arguments: #"{"size":\#(40 << 20)}"#))
        let audits = run.audits
        #expect(await eventually { audits.items.withLock { $0.contains(where: Self.ran) } })
        // A note that has to wait, then the answer behind it: past 256 KiB.
        run.client.send(Self.call(3, arguments: #"{"noise":\#(30 << 20)}"#))
        let logs = run.logs
        #expect(await eventually { logs.text.contains("waits behind the client's output; stopping it") }, "\(logs.text)")
        let stopped = await Self.skim(run, 3)
        #expect(stopped?["error"]?["message"]?.stringValue?.contains("may have run") == true, "\(String(describing: stopped))")
        #expect(audits.items.withLock { $0.filter { $0.tool == "echo" }.map(\.outcome) }.last == .interrupted(grant: nil))
        #expect(await eventually { logs.text.contains("MCP server remote is back") }, "\(logs.text)")
        #expect(await run.finish())
        _ = await offThePool { fixture.stop() }
    }

    /// A reply rv cuts off for its size ends only its own call, with the
    /// size error: the server is not counted gone, and its session goes on.
    @Test(.timeLimit(.minutes(5)))
    func aReplyTooLargeToPassOnEndsOnlyItsCall() async throws {
        let fixture = try RemoteFixture()
        let run = Self.run(fixture)
        defer { run.stopNow() }
        #expect(await run.initialize())
        let size = MCPGatewayRuntime.maximumLineBytes + (1 << 20)
        // As an event stream, then as a JSON body.
        for (id, plain, limit) in [(2, false, "an event larger than"), (3, true, "a reply larger than")] {
            run.client.send(Self.call(id, arguments: #"{"size":\#(size),"plain":\#(plain)}"#))
            let reply = await MCPGatewayRestartRuntimeTests.reply(run, id)
            // It names the limit it passed.
            #expect(String(describing: reply).contains(limit), "\(String(describing: reply)) \(run.logs.text)")
        }
        // Each reply is cut off once (nothing more of it is read), and each
        // call ends once.
        // rv's log lines reach the sink through its relay, after the replies.
        let logs = run.logs
        #expect(await eventually(30) {
            logs.text.components(separatedBy: "sent an event larger than").count == 2
                && logs.text.components(separatedBy: "bytes; dropped").count == 2
        }, "\(logs.text)")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let logged = logs.text
        #expect(logged.components(separatedBy: "sent an event larger than").count == 2, "\(logged)")
        #expect(logged.components(separatedBy: "bytes; dropped").count == 2, "\(logged)")
        #expect(run.audits.items.withLock { $0.filter { $0.tool == "echo" }.count } == 2)
        let answer = await MCPGatewayRestartRuntimeTests.echoes(run, from: 4)
        #expect(answer?["result"] != nil, "\(run.logs.text)")
        #expect(Self.initializes(fixture) == 1, "\(fixture.requests())")
        #expect(run.logs.text.contains("could not reach") == false, "\(run.logs.text)")
        #expect(await run.finish())
        _ = await offThePool { fixture.stop() }
    }

    /// While an earlier answer waits to be taken by the gateway, a later
    /// POST is still let go of: what waits for the gateway holds up none of
    /// the remote's own bookkeeping, so its bytes stop counting.
    @Test(.timeLimit(.minutes(5)))
    func aPostIsLetGoWhileAnEarlierAnswerWaitsToBeTaken() async throws {
        let fixture = try RemoteFixture()
        let taking = DispatchSemaphore(value: 0)
        let delivered = RecordedMessages()
        let remote = MCPRemoteUpstream(
            launch: MCPRemoteLaunch(server: "remote", url: fixture.url("/mcp")),
            deliver: { message in
                delivered.items.withLock { $0.append(message) }
                if message["id"] == .int(1) { _ = taking.wait(timeout: .now() + 120) }
            },
            exited: {}, log: { _ in })
        remote.start()
        remote.send(try Self.initialize(1))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(1) } } })
        let over = Mutex(false)
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))) {
            over.withLock { $0 = true }
        }
        #expect(await eventually(60) { over.withLock { $0 } })
        taking.signal()
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(2) } } })
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }

    /// Only a request's own POST is closed by its cancel, not a response
    /// rv sent that carries the same id.
    @Test func aCancelClosesOnlyTheRequestItNames() throws {
        let call = try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"x"}}"#.utf8))
        let response = try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":7,"result":{}}"#.utf8))
        #expect(MCPRemoteUpstream.closes(call, cancelling: .int(7)))
        #expect(MCPRemoteUpstream.closes(call, cancelling: .int(8)) == false)
        #expect(MCPRemoteUpstream.closes(response, cancelling: .int(7)) == false)
    }

    /// A POST's own session (Linux) is let go once the POST is over, and one
    /// still open when the server is stopped is let go with it.
    @Test(.timeLimit(.minutes(5)))
    func postSessionsAreLetGoWhenTheirPostIsOverOrTheServerStops() async throws {
        let fixture = try RemoteFixture(["--hang-calls"])
        let delivered = RecordedMessages()
        let remote = MCPRemoteUpstream(
            launch: MCPRemoteLaunch(server: "remote", url: fixture.url("/mcp")),
            deliver: { message in delivered.items.withLock { $0.append(message) } }, exited: {}, log: { _ in })
        remote.start()
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#.utf8)))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(1) } } })
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(2) } } })
        #expect(await eventually { remote.postSessionsLive == 0 }, "\(remote.postSessionsLive)")
        remote.send(try JSONValue.parse(Data(Self.call(3).utf8)))
        #expect(await eventually { fixture.requests().contains("REQ POST /mcp tools/call") })
        #if canImport(FoundationNetworking)
        #expect(remote.postSessionsLive == 1)
        #endif
        await offThePool { remote.stop() }
        #expect(await eventually { remote.postSessionsLive == 0 }, "\(remote.postSessionsLive)")
        _ = await offThePool { fixture.stop() }
    }

    /// A call cancelled while its POST waits on a token refresh is not sent
    /// again with the new token.
    @Test(.timeLimit(.minutes(5)))
    func aCallCancelledDuringItsRefreshIsNotSentAgain() async throws {
        let fixture = try RemoteFixture(["--token", "good-token"])
        let token = Mutex("good-token")
        let refreshing = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let first = Mutex(true)
        let authorizer = MCPRemoteAuthorizer(
            token: { token.withLock { $0 } },
            refresh: { _ in
                if first.withLock({ was in defer { was = false }; return was }) {
                    refreshing.signal()
                    _ = proceed.wait(timeout: .now() + 60)
                }
                token.withLock { $0 = "good-token" }
                return true
            })
        let delivered = RecordedMessages()
        let remote = MCPRemoteUpstream(
            launch: MCPRemoteLaunch(server: "auth", url: fixture.url("/mcp")), authorizer: authorizer,
            deliver: { message in delivered.items.withLock { $0.append(message) } }, exited: {}, log: { _ in })
        remote.start()
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#.utf8)))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(1) } } })
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
        token.withLock { $0 = "stale-token" }
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#.utf8)))
        #expect(await offThePool { refreshing.wait(timeout: .now() + 60) } == .success)
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#.utf8)))
        proceed.signal()
        #expect(await eventually { fixture.requests().contains("REQ POST /mcp notifications/cancelled") }, "\(fixture.requests())")
        // A retry would follow the refresh at once; none comes.
        let sent = await eventually(5) { fixture.requests().contains("REQ POST /mcp tools/call") }
        #expect(sent == false, "\(fixture.requests())")
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }

    /// A call cancelled while its retry fetches the new token is not sent:
    /// the cancel is checked where the retry is made.
    @Test(.timeLimit(.minutes(5)))
    func aCallCancelledWhileItsRetryGetsItsTokenIsNotSentAgain() async throws {
        let fixture = try RemoteFixture(["--token", "good-token"])
        let token = Mutex("good-token")
        let armed = Mutex(false)
        let fetching = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let authorizer = MCPRemoteAuthorizer(
            token: {
                if armed.withLock({ was in defer { was = false }; return was }) {
                    fetching.signal()
                    _ = proceed.wait(timeout: .now() + 60)
                }
                return token.withLock { $0 }
            },
            refresh: { _ in
                token.withLock { $0 = "good-token" }
                armed.withLock { $0 = true }
                return true
            })
        let delivered = RecordedMessages()
        let remote = MCPRemoteUpstream(
            launch: MCPRemoteLaunch(server: "auth", url: fixture.url("/mcp")), authorizer: authorizer,
            deliver: { message in delivered.items.withLock { $0.append(message) } }, exited: {}, log: { _ in })
        remote.start()
        remote.send(try Self.initialize(1))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(1) } } })
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
        token.withLock { $0 = "stale-token" }
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#.utf8)))
        #expect(await offThePool { fetching.wait(timeout: .now() + 60) } == .success)
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#.utf8)))
        proceed.signal()
        #expect(await eventually { fixture.requests().contains("REQ POST /mcp notifications/cancelled") }, "\(fixture.requests())")
        // Answered only once the retry was made or refused: the delegate
        // queue is serial.
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#.utf8)))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(3) } } })
        let sent = await eventually(5) { fixture.requests().contains("REQ POST /mcp tools/call") }
        #expect(sent == false, "\(fixture.requests())")
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }

    /// A client's cancel that lands while part of the call's reply is being
    /// read closes only that POST: the close is not lost when what was read
    /// is put back, so the server is not taken for gone.
    @Test(.timeLimit(.minutes(5)))
    func aCancelWhilePartOfTheReplyIsReadClosesOnlyThatCall() async throws {
        let fixture = try RemoteFixture(["--hang-calls", "--hang-notes"])
        let exits = Mutex(0)
        let logged = Mutex<[String]>([])
        let box = Mutex<MCPRemoteUpstream?>(nil)
        let cancelled = Mutex(false)
        let delivered = RecordedMessages()
        let cancel = try JSONValue.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#.utf8))
        let remote = MCPRemoteUpstream(
            launch: MCPRemoteLaunch(server: "remote", url: fixture.url("/mcp")),
            deliver: { message in delivered.items.withLock { $0.append(message) } },
            exited: { exits.withLock { $0 += 1 } }, log: { line in logged.withLock { $0.append(line) } },
            whileReceiving: { request in
                guard request["id"] == .int(2), cancelled.withLock({ was in defer { was = true }; return was == false }) else {
                    return
                }
                box.withLock { $0 }?.send(cancel)
            })
        box.withLock { $0 = remote }
        defer { box.withLock { $0 = nil } }
        remote.start()
        remote.send(try Self.initialize(1))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(1) } } })
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
        remote.send(try JSONValue.parse(Data(Self.call(2).utf8)))
        #expect(await eventually { cancelled.withLock { $0 } }, "\(fixture.requests())")
        #expect(await eventually { fixture.requests().contains("CLOSED call 2") }, "\(fixture.requests())")
        let gone = await eventually(5) { exits.withLock { $0 } > 0 }
        #expect(gone == false, "\(logged.withLock { $0 })")
        #expect(logged.withLock { $0 }.contains { $0.contains("could not reach") } == false, "\(logged.withLock { $0 })")
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#.utf8)))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(3) } } })
        #expect(delivered.items.withLock { $0.contains { $0["id"] == .int(2) } } == false)
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }

    /// A 401 retry's body counts against the bound as the first try's did:
    /// once the first body went out, the retry is counted again, and let go
    /// once its own body has gone out.
    @Test(.timeLimit(.minutes(5)))
    func aRetrysBodyCountsAgainstTheBoundAsTheFirstDid() async throws {
        let fixture = try RemoteFixture(["--token", "good-token", "--hang-calls"])
        let token = Mutex("good-token")
        let authorizer = MCPRemoteAuthorizer(
            token: { token.withLock { $0 } },
            refresh: { _ in
                token.withLock { $0 = "good-token" }
                return true
            })
        let charged = Mutex<[Int]>([])
        let released = Mutex(0)
        let firstLetGo = Mutex(false)
        let delivered = RecordedMessages()
        let remote = MCPRemoteUpstream(
            launch: MCPRemoteLaunch(server: "auth", url: fixture.url("/mcp")), authorizer: authorizer,
            deliver: { message in delivered.items.withLock { $0.append(message) } }, exited: {}, log: { _ in },
            recharge: { bytes in
                charged.withLock { $0.append(bytes) }
                return { released.withLock { $0 += 1 } }
            })
        remote.start()
        remote.send(try Self.initialize(1))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(1) } } })
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
        token.withLock { $0 = "stale-token" }
        let call = try JSONValue.parse(Data(Self.call(2).utf8))
        remote.send(call) { firstLetGo.withLock { $0 = true } }
        #expect(await eventually { fixture.requests().contains("REQ POST /mcp tools/call") }, "\(fixture.requests())")
        #expect(await eventually { firstLetGo.withLock { $0 } })
        #expect(await eventually { released.withLock { $0 } == 1 }, "\(charged.withLock { $0 })")
        #expect(charged.withLock { $0 } == [call.compactText.utf8.count])
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }
}

/// Log lines a test collects.
final class LoggedLines: Sendable {
    let items = Mutex<[String]>([])
}
