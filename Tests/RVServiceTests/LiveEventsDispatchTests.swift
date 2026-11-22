import Foundation
import RVDomain
import RVIPC
import RVPolicy
import Synchronization
import Testing
@testable import RVIsolation
@testable import RVService

/// `events` through `ServiceRuntime`: what a hook decision publishes, who
/// may read it, hello skew, and that stuck subscribers leave the hook path
/// alone.
@Suite("Live events dispatch", .serialized)
struct LiveEventsDispatchTests {
    // MARK: - Decisions

    @Test func hookDenyPublishesOneRedactedDecision() async throws {
        let runtime = try isolatedRuntime()
        let reply = try await hook(runtime, command: "git reset --hard", cwd: "/tmp/rv-hook-fixture")
        #expect(reply.exitCode == 0)
        let decision = try await nextDecision(runtime)
        #expect(decision.verdict == .denied)
        #expect(decision.rule == "core.git:reset-hard")
        #expect(decision.host == .claude)
        #expect(decision.tool == .bash)
        #expect(decision.command == "git reset --hard")
        #expect(decision.cwd == "/tmp/rv-hook-fixture")
        #expect(decision.session == "abc-123")
        #expect(decision.timedOut == false)
    }

    @Test func hookAllowPublishesAnAllowedDecision() async throws {
        let runtime = try isolatedRuntime()
        _ = try await hook(runtime, command: "git status", cwd: "/tmp/rv-hook-fixture")
        let decision = try await nextDecision(runtime)
        #expect(decision.verdict == .allowed)
        #expect(decision.rule == nil)
        #expect(decision.command == "git status")
    }

    @Test func fileDecisionCarriesThePathNotACommand() async throws {
        let runtime = try isolatedRuntime()
        let stdin = """
            {"hook_event_name":"PreToolUse","session_id":"abc-123","cwd":"/tmp/rv-oracle",\
            "tool_name":"Read","tool_input":{"file_path":"/tmp/rv-oracle/.env"}}
            """
        _ = try await hookRaw(runtime, stdin: stdin)
        let decision = try await nextDecision(runtime)
        #expect(decision.tool == .read)
        #expect(decision.command == nil)
        #expect(decision.path == "/tmp/rv-oracle/.env")
        #expect(decision.verdict == .denied)
    }

    /// The same redaction as rvd's local records: credentials, `$HOME`,
    /// control characters, the length cap; session ids only when opaque.
    @Test func decisionsAreRedactedLikeTheLocalRecords() async throws {
        let homeURL = try isolatedHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let runtime = try isolatedRuntime(home: home)
        let secret = "ghp_" + String(repeating: "A", count: 36)
        let command = "GITHUB_TOKEN=\(secret) git -C \(homeURL.path)/proj status\techo \(String(repeating: "x", count: 900))"
        _ = try await hook(runtime, command: command, cwd: homeURL.path + "/proj", session: "not an id; rm -rf /")
        let decision = try await nextDecision(runtime)
        let shown = try #require(decision.command)
        #expect(shown.contains(secret) == false)
        #expect(shown.contains(homeURL.path) == false)
        #expect(shown.contains("~/proj"))
        #expect(shown.contains("\t") == false)
        #expect(shown.utf8.count <= LiveDecision.maxTextBytes + "…".utf8.count)
        #expect(shown.hasSuffix("…"))
        #expect(decision.cwd == "~/proj")
        #expect(decision.session == nil)
    }

    @Test func timedOutReplyIsPublishedAsRefusedUnderTheTimeoutRule() async throws {
        let capture = HookDecisionTap.Capture(
            result: EvaluationResult(outcome: .plain), subject: .shell(ShellCommand(rawValue: "git status")),
            cwd: nil, host: .claude, startedAt: Date(timeIntervalSince1970: 0), session: nil)
        let decision = capture.liveDecision(timedOut: true, home: nil)
        #expect(decision.verdict == .refused)
        #expect(decision.rule == "rv.timeout")
        #expect(decision.timedOut)
    }

    // MARK: - Asks and resolutions

    @Test func pendingRowsPublishAsksAndResolutions() async throws {
        let store = PendingApprovalStore(
            baseDirectory: try isolatedHomeDirectory().appendingPathComponent("pending", isDirectory: true))
        let runtime = hookTestRuntime(
            home: try HomeDirectory(validating: isolatedHomeDirectory().path),
            allowOnceDirectory: try isolatedAllowOnceDirectory(),
            pendingApprovals: .coordinator(store))
        let start = try await poll(runtime, EventsParams())
        _ = try await hook(runtime, command: "git reset --hard", cwd: "/tmp/rv-hook-fixture")
        // The ask is recorded while the hook runs; its decision publishes
        // after the reply, so either may come first.
        var kinds: [String] = []
        var askID: ApprovalID?
        var cursor = start.cursor
        for _ in 0..<10 where askID == nil || kinds.contains("decision") == false {
            let reply = try await poll(runtime, EventsParams(stream: start.stream, after: cursor, waitMs: 2_000))
            cursor = reply.cursor
            for event in reply.events {
                kinds.append(event.payload.kind)
                if case .ask(let ask) = event.payload { askID = ask.item.id }
            }
        }
        let id = try #require(askID, "a host ask must publish an ask event; saw \(kinds)")
        #expect(kinds.contains("decision"))
        _ = try await store.cancel(id: id, now: Date())
        var resolution: LiveResolution?
        for _ in 0..<10 where resolution == nil {
            let reply = try await poll(runtime, EventsParams(stream: start.stream, after: cursor, waitMs: 2_000))
            cursor = reply.cursor
            resolution = reply.events.lazy.compactMap { event -> LiveResolution? in
                if case .resolution(let resolution) = event.payload { return resolution }
                return nil
            }.first
        }
        #expect(resolution == LiveResolution(id: id, host: .claude, outcome: .canceled))
    }

    // MARK: - Who may subscribe

    @Test func onlyAPeerRunningAsTheOwnerMaySubscribe() async throws {
        let runtime = try isolatedRuntime()
        let request = IPCRequest(method: .events(EventsParams()))
        let anonymous = await runtime.dispatch(request, context: .unauthenticated)
        #expect(anonymous.result == .error(.authorizationDenied))
        let otherUser = await runtime.dispatch(request, context: peer(uid: ServiceMethodAuthorization.ownerUserID &+ 1))
        #expect(otherUser.result == .error(.authorizationDenied))
        // The same-UID socket session flag does not bypass the uid check.
        let flagged = await runtime.dispatch(
            request, context: peer(uid: ServiceMethodAuthorization.ownerUserID &+ 1), sameUIDSocket: true)
        #expect(flagged.result == .error(.authorizationDenied))
        let owner = await runtime.dispatch(request, context: ownerContext())
        guard case .events = owner.result else {
            Issue.record("the owner's peer must read events, got \(owner.result)")
            return
        }
    }

    /// The macOS socket listener's call shape: no captured peer, the
    /// same-user flag set only after `getpeereid` matched rvd's uid at
    /// accept. Runs on every platform, so the macOS path is pinned here too.
    @Test func macSocketSessionShapeReadsEvents() async throws {
        let runtime = try isolatedRuntime()
        let body = try IPCJSON.encode(IPCRequest(method: .events(EventsParams())))
        let flagged = await runtime.handleIncoming(body, handshakeOK: true, sameUIDSocket: true)
        let reply = try IPCJSON.decode(IPCResponse.self, from: flagged.frame)
        guard case .events = reply.result else {
            Issue.record("a same-user socket session must read events, got \(reply.result)")
            return
        }
        let unflagged = await runtime.handleIncoming(body, handshakeOK: true, sameUIDSocket: false)
        #expect(try IPCJSON.decode(IPCResponse.self, from: unflagged.frame).result == .error(.authorizationDenied))
    }

    /// Asks, resolutions, unknown kinds and session ids follow
    /// `pendingList`'s gate per caller; decisions are a same-user read.
    @Test func eachCallerSeesNoMoreThanPendingListShowsIt() async throws {
        let runtime = try isolatedRuntime()
        let bus = runtime.events
        bus.publish(.decision(LiveDecision(
            verdict: .denied, host: .claude, tool: .bash, command: "git reset --hard", session: "abc-123")), at: Date())
        bus.publish(.ask(LiveAsk(item: PendingListItem(
            id: ApprovalID(rawValue: "ask-1"), host: .pi, folder: "ws", actionKind: "git push",
            fingerprint: ActionFingerprint(rawValue: "shell:git"),
            identity: ApprovalIdentity(session: SessionID(validating: "sess")!, agent: .pi)))), at: Date())
        bus.publish(.resolution(LiveResolution(id: ApprovalID(rawValue: "ask-1"), host: .pi, outcome: .deny)), at: Date())
        bus.publish(.unknown(kind: "proposal"), at: Date())
        let request = IPCRequest(method: .events(EventsParams(after: 0)))

        // An owner XPC peer with no role (pendingList refuses it).
        let roleless = try events(await runtime.dispatch(request, context: ownerContext()))
        #expect(roleless.events.map(\.payload.kind) == ["decision"])
        #expect(roleless.cursor == 4)
        guard case .decision(let hidden) = roleless.events.first?.payload else {
            Issue.record("the decision must stay visible")
            return
        }
        #expect(hidden.session == nil)
        #expect(hidden.command == "git reset --hard")

        // pendingList admits these two: they see every event as published.
        let all = ["decision", "ask", "resolution", "proposal"]
        let socket = try events(await runtime.dispatch(request, context: ownerContext(), sameUIDSocket: true))
        #expect(socket.events.map(\.payload.kind) == all)
        let service = try events(await runtime.dispatch(request, context: ownerServiceContext()))
        #expect(service.events.map(\.payload.kind) == all)
        if case .decision(let shown) = service.events.first?.payload {
            #expect(shown.session == "abc-123")
        }
    }

    // MARK: - Hello skew

    /// A new client asking an rvd that predates `events`: that rvd cannot
    /// decode the method key and answers `decodeFailed`, keeping the
    /// handshake, so the client falls back to polling. A current rvd
    /// treats any method key it does not know the same way; this pins
    /// that path with a key no build knows.
    @Test func olderDaemonAnswersDecodeFailedAndKeepsTheConnection() async throws {
        let runtime = try isolatedRuntime()
        let hello = await runtime.handleIncoming(try IPCJSON.encode(Hello()), handshakeOK: false)
        #expect(hello.handshakeAccepted)
        let future = Data(#"{"id":"\#(UUID().uuidString)","protocol":"rv.ipc.v1","method":{"eventsV9":{}}}"#.utf8)
        let incoming = await runtime.handleIncoming(future, handshakeOK: true, context: ownerContext())
        #expect(incoming.handshakeAccepted)
        let response = try IPCJSON.decode(IPCResponse.self, from: incoming.frame)
        #expect(EventsCall.isUnsupported(response.result))
        // The same connection still serves the old poll.
        let watch = try IPCJSON.encode(IPCRequest(method: .pendingWatch(PendingWatchParams(afterGeneration: 0))))
        let next = await runtime.handleIncoming(watch, handshakeOK: true, context: peerServiceContext())
        let watched = try IPCJSON.decode(IPCResponse.self, from: next.frame)
        #expect(EventsCall.isUnsupported(watched.result) == false)
    }

    /// A client whose hello was refused for skew never reads events, and
    /// `events` has no implicit hello to slip past it.
    @Test func skewedClientGetsHandshakeRequiredNotEvents() async throws {
        let runtime = try isolatedRuntime()
        let hello = await runtime.handleIncoming(
            try IPCJSON.encode(Hello(clientSemver: "2.0.0")), handshakeOK: false)
        #expect(hello.handshakeAccepted == false)
        let body = try IPCJSON.encode(IPCRequest(method: .events(EventsParams())))
        let incoming = await runtime.handleIncoming(body, handshakeOK: false, context: ownerContext())
        let response = try IPCJSON.decode(IPCResponse.self, from: incoming.frame)
        #expect(response.result == .error(.protocolSkew(.handshakeRequired)))
    }

    /// An old client never sends `events`, so the hook path it uses must be
    /// unchanged by the bus: same reply with or without subscribers.
    @Test func oldClientHookReplyIsUnchangedBySubscribers() async throws {
        let quiet = try isolatedRuntime()
        let busy = try isolatedRuntime()
        let parked = parkWirePolls(busy)
        defer { parked.forEach { $0.cancel() } }
        let allowWithout = try await hook(quiet, command: "git status", cwd: "/tmp/rv-hook-fixture")
        let allowWith = try await hook(busy, command: "git status", cwd: "/tmp/rv-hook-fixture")
        #expect(allowWithout == allowWith)
        let denyWithout = try await hook(quiet, command: "git reset --hard", cwd: "/tmp/rv-hook-fixture")
        let denyWith = try await hook(busy, command: "git reset --hard", cwd: "/tmp/rv-hook-fixture")
        #expect(denyWithout.exitCode == denyWith.exitCode)
        #expect(denyWith.stdout.contains("\"permissionDecision\":\"deny\""))
        #expect(denyWithout.stdout.contains("\"permissionDecision\":\"deny\""))
    }

    // MARK: - Acceptance: a stuck subscriber never slows a hook

    /// Subscribers that never read (an in-process subscription never
    /// iterated, every wire poll slot parked) while hooks run: no hook
    /// times out, hook latency stays within noise of a runtime with no
    /// subscribers, and every decision is still published.
    @Test func stuckSubscribersLeaveHookLatencyUnchanged() async throws {
        let commands = (0..<20).map { $0.isMultiple(of: 2) ? "git status" : "git reset --hard" }
        let quiet = try isolatedRuntime()
        _ = try await hook(quiet, command: "git status", cwd: "/tmp/rv-hook-fixture") // warm
        let baseline = try await timeHooks(quiet, commands)

        let busy = try isolatedRuntime()
        _ = try await hook(busy, command: "git status", cwd: "/tmp/rv-hook-fixture") // warm
        let neverRead = busy.events.subscribe()
        let parked = parkWirePolls(busy)
        defer { parked.forEach { $0.cancel() } }
        try? await Task.sleep(for: .milliseconds(50))
        let headBefore = busy.events.head
        let loaded = try await timeHooks(busy, commands)

        #expect(loaded.timedOut == 0)
        #expect(loaded.elapsed < baseline.elapsed * 3 + .seconds(1),
                "hooks took \(loaded.elapsed) with stuck subscribers vs \(baseline.elapsed) without")
        #expect(loaded.slowest < testHookBudget)
        try await waitUntil { busy.events.head >= headBefore + UInt64(commands.count) }
        _ = neverRead
    }

    // MARK: - Helpers

    private struct HookTiming {
        var elapsed: Duration
        var slowest: Duration
        var timedOut: Int
    }

    private func timeHooks(_ runtime: ServiceRuntime, _ commands: [String]) async throws -> HookTiming {
        let clock = ContinuousClock()
        var timing = HookTiming(elapsed: .zero, slowest: .zero, timedOut: 0)
        for command in commands {
            let started = clock.now
            let reply = try await hook(runtime, command: command, cwd: "/tmp/rv-hook-fixture")
            let took = clock.now - started
            timing.elapsed += took
            timing.slowest = max(timing.slowest, took)
            if reply.stdout.contains("timed out") { timing.timedOut += 1 }
        }
        return timing
    }

    /// Fills every wire waiter slot with a poll nobody will collect.
    private func parkWirePolls(_ runtime: ServiceRuntime) -> [Task<Void, Never>] {
        (0..<LiveEventBus.maxWireWaiters).map { _ in
            Task {
                let request = IPCRequest(method: .events(EventsParams(waitMs: EventsParams.maxWaitMs)))
                while Task.isCancelled == false {
                    _ = await runtime.dispatch(request, context: ownerContext())
                }
            }
        }
    }

    private func hook(
        _ runtime: ServiceRuntime, command: String, cwd: String, session: String = "abc-123"
    ) async throws -> HookEvaluateReply {
        let input: [String: Any] = [
            "hook_event_name": "PreToolUse", "session_id": session, "cwd": cwd,
            "tool_name": "Bash", "tool_input": ["command": command],
        ]
        let stdin = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        return try await hookRaw(runtime, stdin: stdin)
    }

    private func hookRaw(_ runtime: ServiceRuntime, stdin: String) async throws -> HookEvaluateReply {
        let request = IPCRequest(method: .hookEvaluate(HookEvaluateParams(
            host: .claude, stdin: stdin, clientSemver: ProtocolVersion.serviceSemver)))
        let response = await runtime.dispatch(request, context: peerHookContext())
        guard case .hookEvaluate(let reply) = response.result else {
            throw LiveEventsTestError.unexpected("\(response.result)")
        }
        return reply
    }

    private func events(_ response: IPCResponse) throws -> EventsReply {
        guard case .events(let reply) = response.result else {
            throw LiveEventsTestError.unexpected("\(response.result)")
        }
        return reply
    }

    /// Polls as a same-user socket session, which `pendingList` admits, so
    /// every event arrives as published (`LiveEventView`).
    private func poll(_ runtime: ServiceRuntime, _ params: EventsParams) async throws -> EventsReply {
        let response = await runtime.dispatch(
            IPCRequest(method: .events(params)), context: ownerContext(), sameUIDSocket: true)
        guard case .events(let reply) = response.result else {
            throw LiveEventsTestError.unexpected("\(response.result)")
        }
        return reply
    }

    /// The first decision published on `runtime` (decisions publish off
    /// the hook's task, so this waits for it).
    private func nextDecision(_ runtime: ServiceRuntime) async throws -> LiveDecision {
        for _ in 0..<20 {
            let reply = try await poll(runtime, EventsParams(after: 0, waitMs: 500))
            for event in reply.events {
                if case .decision(let decision) = event.payload { return decision }
            }
        }
        throw LiveEventsTestError.unexpected("no decision published")
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("condition never held")
    }
}

private enum LiveEventsTestError: Error {
    case unexpected(String)
}

/// A kernel-attested peer running as `uid`, with no component role.
private func peer(uid: UInt32) -> AuthenticatedRequestContext {
    let id = UUID()
    return .captured(
        peer: AuthenticatedPeer.socketPeer(processID: 4242, effectiveUserID: uid, connectionID: id),
        connectionID: id)
}

/// A peer running as rvd's own user: rv term, the menu bar app.
private func ownerContext() -> AuthenticatedRequestContext {
    peer(uid: ServiceMethodAuthorization.ownerUserID)
}

/// A `controlRead` component (role `.service`) running as rvd's user.
private func ownerServiceContext() -> AuthenticatedRequestContext {
    let code = PeerCodeIdentity(
        identifier: "events-service-fixture", teamIdentifier: nil, cdHash: Data([11]),
        executablePath: "/events-service-fixture", isAdHoc: true, hardenedRuntime: true,
        injectionExceptions: [])
    let id = UUID()
    let peer = AuthenticatedPeer(
        evidence: PlatformPeerEvidence(
            processID: 4244, effectiveUserID: ServiceMethodAuthorization.ownerUserID,
            auditToken: Data([11]), codeIdentity: code, componentRole: .service),
        connectionID: id)
    return .captured(peer: peer, connectionID: id)
}
