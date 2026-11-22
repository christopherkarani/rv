#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Why `rv mcp serve` starts nothing, kept as a value so the same refusal
/// reaches the owner (stderr, `log`) and the agent (a JSON-RPC error on its
/// first request), each in its own words.
///
/// The agent's words come only from `cause`, never from `log`: `log` may
/// carry resolver or sandbox detail meant for the owner, and the agent's
/// channel is the model's context. Server and secret names are the only
/// configuration text the agent sees, escaped as every gateway field is.
public struct MCPServeRefusal: Error, Sendable, Equatable {
    public enum Cause: Sendable, Equatable {
        /// mcp.json does not verify as what rv wrote or the owner trusted.
        case untrusted
        /// No key custodian here, so no mcp.json can be trusted.
        case trustUnavailable
        /// mcp.json changed between the read and the check.
        case changedWhileChecked
        /// mcp.json or organization policy cannot be read or used.
        case configurationUnusable
        case noServers
        case unknownServer(String)
        case blocked(String)
        case secretUndefined(server: String, secret: String)
        case secretUnavailable(server: String, secret: String)
        /// rv will not run it uncaged, or cannot build its cage.
        case notSealed
        /// Planned not to start for another reason (placeholders this host
        /// cannot lease).
        case refusedHere
        case secretsUnusable
        case signalsUnavailable
    }

    /// The servers this serve was asked for (empty when mcp.json could not be read).
    public var servers: [String]
    public var cause: Cause
    /// The owner's line, unchanged from what serve always wrote to stderr.
    public var log: String

    public init(servers: [String], cause: Cause, log: String) {
        self.servers = servers
        self.cause = cause
        self.log = log
    }

    /// The cause of a launch planning failure.
    public static func cause(of error: MCPLaunchError) -> Cause {
        switch error {
        case .unknownServer(let name): .unknownServer(name)
        case .blocked(let name): .blocked(name)
        case .secretUndefined(let server, let secret): .secretUndefined(server: server, secret: secret)
        case .secretUnavailable(let server, let secret, _): .secretUnavailable(server: server, secret: secret)
        case .sandbox: .notSealed
        case .untrustedRemote: .untrusted
        }
    }

    /// Why, in a few plain words (after "is off ·").
    public var reason: String {
        switch cause {
        case .untrusted: "mcp.json is untrusted"
        case .trustUnavailable: "mcp.json can't be trusted without a key custodian"
        case .changedWhileChecked: "mcp.json changed while rv checked it"
        case .configurationUnusable: "rv can't use its MCP setup"
        case .noServers: "mcp.json defines no servers"
        case .unknownServer(let name): "mcp.json has no server named \(MCPDisplayedText.field(name))"
        case .blocked(let name): "\(MCPDisplayedText.field(name)) is blocked in mcp.json"
        case .secretUndefined(_, let secret): "secret \(MCPDisplayedText.field(secret)) is not set up"
        case .secretUnavailable(_, let secret): "rv could not read secret \(MCPDisplayedText.field(secret))"
        case .notSealed: "not sealed: rv won't run it without its sandbox"
        case .refusedHere: "rv won't start it on this host"
        case .secretsUnusable: "rv can't read secrets.json"
        case .signalsUnavailable: "rv can't catch stop signals here"
        }
    }

    /// The one command that fixes it, for the person to run.
    public var next: String {
        switch cause {
        case .untrusted, .changedWhileChecked: "rv mcp trust"
        case .trustUnavailable: "sudo rv mcp custodian install"
        case .configurationUnusable, .notSealed, .refusedHere, .signalsUnavailable: "rv mcp check"
        case .noServers: "rv mcp import"
        case .unknownServer, .blocked: "rv mcp list"
        case .secretUndefined(_, let secret): "rv secrets set \(MCPDisplayedText.field(secret))"
        case .secretUnavailable, .secretsUnusable: "rv secrets check"
        }
    }

    /// What is off: the servers by name, or rv's MCP gateway.
    var subject: String {
        let shown = servers.map(MCPDisplayedText.field)
        switch shown.count {
        case 0: return "rv's MCP gateway is"
        case 1: return "\(shown[0]) is"
        case 2...3: return shown.joined(separator: ", ") + " are"
        default: return shown.prefix(3).joined(separator: ", ") + " +\(shown.count - 3) more are"
        }
    }

    /// The two lines the agent sees, in the v6 "off" frame's words.
    public var agentMessage: String {
        "✕ \(subject) off · \(reason) · nothing ran\n→ ask your user: \(next)"
    }

    /// JSON-RPC server error (implementation-defined range).
    public static let errorCode = -32000

    /// The error answer to request `id`. `data.rv` is for clients that show
    /// structured detail; the message alone says everything.
    public func errorResponse(id: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .int(Self.errorCode),
                "message": .string(agentMessage),
                "data": .object([
                    "rv": .object([
                        "state": .string("off"),
                        "servers": .array(servers.map { .string(MCPDisplayedText.field($0)) }),
                        "reason": .string(reason),
                        "next": .string(next),
                    ])
                ]),
            ]),
        ])
    }

    /// The cause when every planned connection is refused: `notSealed`
    /// when each was refused for its sandbox; nil when any would start.
    public static func cause(ofPlanned connections: [MCPUpstreamConnection]) -> Cause? {
        var sealing = true
        for connection in connections {
            guard case .refused(_, let refusal) = connection else { return nil }
            if case .sandbox = refusal { continue }
            sealing = false
        }
        guard connections.isEmpty == false else { return nil }
        return sealing ? .notSealed : .refusedHere
    }

    /// The answer to one client line: an error for every request (a
    /// message with a method and an id), nothing for notifications or
    /// responses, a parse error for a line that is not JSON.
    public func answer(_ line: Data) -> JSONValue? {
        guard let message = try? JSONValue.parse(line) else {
            return .object([
                "jsonrpc": .string("2.0"), "id": .null,
                "error": .object(["code": .int(-32700), "message": .string("Parse error")]),
            ])
        }
        guard message.objectValue != nil, message["method"]?.stringValue != nil, let id = message["id"] else {
            return nil
        }
        return errorResponse(id: id)
    }
}

/// Serves an `MCPServeRefusal` over stdio: every request the client sends
/// gets the refusal as its error, so the host shows the agent why the
/// server is off instead of an empty pipe.
///
/// It starts nothing, resolves nothing and reads no configuration: it only
/// holds the refusal it was given. It is bounded every way: lines over
/// `maximumLineBytes` are dropped whole, it answers at most
/// `maximumAnswers` requests, and it stops at EOF, on a failed write, or
/// after `idleSeconds` with no input.
public enum MCPRefusalResponder {
    public static let maximumLineBytes = 1024 * 1024
    public static let maximumAnswers = 32
    public static let idleSeconds: Int32 = 30

    /// Returns how many requests were answered.
    @discardableResult
    public static func serve(
        _ refusal: MCPServeRefusal, input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO,
        idleSeconds: Int32 = idleSeconds
    ) -> Int {
        var answered = 0
        var line: [UInt8] = []
        var overflowing = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        func handle(_ bytes: [UInt8]) -> Bool {
            var trimmed = bytes
            if trimmed.last == 0x0D { trimmed.removeLast() }
            guard trimmed.isEmpty == false, let reply = refusal.answer(Data(trimmed)) else { return true }
            guard writeLine(output, reply.compactText) else { return false }
            answered += 1
            return answered < maximumAnswers
        }
        reading: while true {
            var poller = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, idleSeconds * 1000)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { break }
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(input, base, raw.count)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            var start = 0
            for index in 0..<n where buffer[index] == 0x0A {
                if overflowing == false {
                    line += buffer[start..<index]
                    // The newline can arrive in the chunk that crosses the cap.
                    if line.count <= maximumLineBytes {
                        guard handle(line) else { break reading }
                    }
                }
                line.removeAll(keepingCapacity: true)
                overflowing = false
                start = index + 1
            }
            if overflowing == false {
                line += buffer[start..<n]
                if line.count > maximumLineBytes {
                    overflowing = true
                    line.removeAll()
                }
            }
        }
        if overflowing == false, line.isEmpty == false, answered < maximumAnswers { _ = handle(line) }
        return answered
    }

    /// One JSON-RPC line, written whole; false when the reader is gone.
    static func writeLine(_ fd: Int32, _ text: String) -> Bool {
        let bytes = Array((text + "\n").utf8)
        var written = 0
        var waits = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base + written, raw.count - written)
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                // A client that never reads is given ten seconds, not forever.
                waits += 1
                guard waits <= 10 else { return false }
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&poller, 1, 1000)
                continue
            }
            guard n > 0 else { return false }
            written += n
        }
        return true
    }
}

extension MCPServeRefusal {
    /// Why `rv mcp serve --server name` would start nothing, judged from
    /// mcp.json and its integrity alone, as serve judges them before any
    /// secret is resolved; nil when serve would start it. It mirrors
    /// `MCPRun.upstreamPlan` and `MCPLaunchPlanner.plan`: an untrusted
    /// file refuses everything, a local server needs a usable sandbox
    /// where the cage is enforced, and where it is not, a server that asks
    /// for a sandbox (or every local server under the organization's
    /// `requireSandbox`) is refused.
    public static func cause(
        serving name: String, configuration: MCPConfiguration, integrity: MCPIntegrityStatus,
        requireSandbox: Bool = MCPSandbox.enforced
    ) -> Cause? {
        switch integrity {
        case .unsupportedPlatform: return .trustUnavailable
        case .untrusted: return .untrusted
        case .noConfiguration, .trusted: break
        }
        if configuration.isBlocked(name) { return .blocked(name) }
        guard let server = configuration.server(named: name) else { return .unknownServer(name) }
        guard server.remote == nil else { return nil }
        if requireSandbox {
            guard let sandbox = server.sandbox, sandbox.network == false else { return .notSealed }
            return nil
        }
        if configuration.managed?.mcp.requireSandbox == true || server.sandbox != nil { return .notSealed }
        return nil
    }

    /// The short why `rv mcp list` shows after "not governed:".
    public var listReason: String {
        switch cause {
        case .untrusted: "mcp.json untrusted"
        case .trustUnavailable: "no key custodian to trust mcp.json"
        case .notSealed: "not sealed"
        default: reason
        }
    }
}
