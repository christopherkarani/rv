import Foundation

/// Bringing a server back. One that was ready this session and then went
/// away (it exited, or rv stopped it) is started again after
/// `restartDelay`, at most `maximumRelaunches` times in any
/// `restartWindow`; past that it stays failed for the session. One that was
/// never ready is never started again. Nothing that was in flight is sent
/// again, and a call that arrives meanwhile is refused at once. After a
/// relaunch the server is initialized and listed again (through
/// `settleListing`, so a changed definition is tainted as any mid-session
/// change is) before any call reaches it.
extension MCPGatewayCore {
    static let restartWindow: TimeInterval = 600
    static let maximumRelaunches = 5
    static let maximumRestartDelay: TimeInterval = 30
    /// How long a server has to answer rv's `ping` after a call timed out.
    static let pingTimeout: TimeInterval = 10

    /// 1, 2, 4 … seconds, never more than `maximumRestartDelay`.
    static func restartDelay(afterRelaunches count: Int) -> TimeInterval {
        min(maximumRestartDelay, TimeInterval(1 << min(max(count, 0), 16)))
    }

    /// Sets the phase; the client is told the tools changed when the server
    /// leaves or rejoins `ready` and it was told tools exist.
    mutating func setPhase(_ server: String, _ phase: UpstreamPhase) -> [MCPGatewayOutput] {
        let was = phases[server]
        phases[server] = phase
        guard clientToldTools, (was == .ready) != (phase == .ready) else { return [] }
        return [.toClient(Self.notification("notifications/tools/list_changed", nil))]
    }

    /// Whether the server would be started again once it is gone.
    func restartable(_ server: String) -> Bool {
        guard everReady.contains(server) else { return false }
        if case .failed? = phases[server] { return false }
        return true
    }

    /// rv is stopping the server for `reason`. Its exit decides what comes next.
    mutating func stopped(_ server: String, _ reason: String) -> [MCPGatewayOutput] {
        setPhase(server, restartable(server) ? .restarting(reason, .stopping) : .failed(reason))
    }

    /// The server is gone: started again after its delay, or failed for good.
    mutating func afterExit(_ server: String) -> [MCPGatewayOutput] {
        let reason: String
        switch phases[server] {
        // A server already failed keeps its first reason (a start that
        // timed out, then the stopped process's exit).
        case .failed?: return []
        case .restarting(let why, _)?: reason = why
        case .starting?, .ready?, nil: reason = "process exited"
        }
        guard restartable(server) else { return setPhase(server, .failed(reason)) }
        let now = deadlineClock()
        let recent = (relaunches[server] ?? []).filter { now.timeIntervalSince($0) < Self.restartWindow }
        relaunches[server] = recent
        let shown = MCPDisplayedText.field(server)
        guard recent.count < Self.maximumRelaunches else {
            let minutes = Self.seconds(Self.restartWindow / 60)
            let final = "it went away again after \(recent.count) restarts within \(minutes) minutes, "
                + "so rv stopped restarting it; restart the MCP client to start it again"
            return setPhase(server, .failed(final)) + [.log("MCP server \(shown): \(final)")]
        }
        let delay = Self.restartDelay(afterRelaunches: recent.count)
        return setPhase(server, .restarting(reason, .waiting(until: now.addingTimeInterval(delay))))
            + [.log("MCP server \(shown) is gone (\(reason)); restarting it in \(Self.seconds(delay)) s")]
    }

    /// Every server whose delay is over is started again, in `order`.
    mutating func dueRestarts() -> [MCPGatewayOutput] {
        let now = deadlineClock()
        var outputs: [MCPGatewayOutput] = []
        for server in order {
            guard case .restarting(let reason, .waiting(let until))? = phases[server], until <= now else { continue }
            phases[server] = .restarting(reason, .launching)
            relaunches[server, default: []].append(now)
            outputs.append(.restartUpstream(server: server))
        }
        return outputs
    }

    /// The runtime started it again: it is initialized as at serve start.
    mutating func upstreamRelaunched(_ server: String) -> [MCPGatewayOutput] {
        guard case .restarting(_, .launching)? = phases[server] else { return [] }
        return [initialize(server)]
    }

    /// rv's own listing of a relaunched server; nobody gets its answer.
    mutating func relist(_ server: String) -> [MCPGatewayOutput] {
        let fanout = nextID
        nextID += 1
        fanouts[fanout] = ListFanout(client: .null, remaining: [server], tools: [], search: nil, relaunch: server)
        let id = allocate(.list(fanout: fanout, server: server, deadline: deadlineClock().addingTimeInterval(deadlines.list)))
        return [.toUpstream(server: server, message: Self.request(id: .int(id), method: "tools/list", params: nil))]
    }

    /// Listed again after a relaunch: ready, or stopped when its listing
    /// failed (which counts as one more time it went away).
    mutating func relisted(_ server: String, failed: Bool) -> [MCPGatewayOutput] {
        guard case .restarting(let reason, .launching)? = phases[server] else { return [] }
        let shown = MCPDisplayedText.field(server)
        guard failed == false else {
            return setPhase(server, .restarting(reason, .stopping)) + [
                .log("MCP server \(shown) did not list its tools after a restart; stopping it"),
                .stopUpstream(server: server),
            ]
        }
        return [.log("MCP server \(shown) is back")] + setPhase(server, .ready)
    }

    /// After a call to `server` timed out: one `ping` at a time, so a server
    /// that no longer answers anything is found.
    mutating func ping(_ server: String, now: Date) -> [MCPGatewayOutput] {
        guard phases[server] == .ready else { return [] }
        let pinging = pending.values.contains { entry in
            if case .ping(let owner, _) = entry { owner == server } else { false }
        }
        guard pinging == false else { return [] }
        let id = allocate(.ping(server: server, deadline: now.addingTimeInterval(Self.pingTimeout)))
        return [.toUpstream(server: server, message: Self.request(id: .int(id), method: "ping", params: nil))]
    }

    /// No answer to rv's `ping`: the server is hung, so it is stopped (and
    /// restarted, under the same policy as an exit).
    mutating func pingUnanswered(_ server: String) -> [MCPGatewayOutput] {
        guard phases[server] == .ready else { return [] }
        let seconds = Self.seconds(Self.pingTimeout)
        return stopped(server, "it stopped answering") + [
            .log("MCP server \(MCPDisplayedText.field(server)) did not answer a ping within \(seconds) s "
                + "after a call timed out; stopping it"),
            .stopUpstream(server: server),
        ]
    }

    /// A call that arrives while its server is being brought back, or a
    /// prompt accepted then: refused now, never queued, and audited as not
    /// forwarded (a prompt declined with its approval id).
    func restarting(
        client: JSONValue, server: String, tool: String, decision: MCPToolDecision, keys: [String],
        approvalID: String?, reason: String
    ) -> [MCPGatewayOutput] {
        [
            .audit(MCPCallRecord(
                server: server, tool: tool, decision: decision == .ask ? .ask : .allow, argumentKeys: keys, isError: true,
                reason: "upstream restarting: \(reason)", outcome: Self.notForwarded(approvalID))),
            .toClient(Self.error(
                id: client, code: -32603,
                message: "MCP server \(server) is unavailable: \(reason); rv is restarting it. "
                    + "The call was not run; try it again in a few seconds.")),
        ]
    }
}
