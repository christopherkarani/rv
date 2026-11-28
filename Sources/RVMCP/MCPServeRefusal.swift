#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIsolation

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
        /// `${secret:NAME}` is in this local server's args; rv never puts a
        /// secret value in a process's arguments.
        case secretInArguments(server: String, secret: MCPArgumentSecret)
        /// The cage is enforced here and this local server has no sandbox.
        case noSandbox(String)
        /// The cage is enforced here and its sandbox leaves the network open.
        case openNetwork(String)
        /// rv cannot build the cage it asks for (or organization policy
        /// requires) on this host, or building it failed.
        case cageUnavailable
        /// Its `placeholders` cannot be used.
        case placeholders(server: String, MCPPlaceholderRefusal)
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
        case .sandbox: .cageUnavailable
        case .untrustedRemote: .untrusted
        }
    }

    /// The cause of a placeholder refusal: a missing secret or a sandbox
    /// problem in the same words as any server's.
    static func cause(server: String, placeholders refusal: MCPPlaceholderRefusal) -> Cause {
        switch refusal {
        case .unknownSecret(let secret): .secretUndefined(server: server, secret: secret)
        case .noSandbox: .noSandbox(server)
        case .unconfinedNetwork: .openNetwork(server)
        case .cageUnavailable, .uncaged: .cageUnavailable
        default: .placeholders(server: server, refusal)
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
        case .secretInArguments(_, let found): found.reason
        case .noSandbox: "not sealed: it has no sandbox"
        case .openNetwork: "not sealed: its sandbox network is open"
        case .cageUnavailable: "rv can't seal it on this host"
        case .placeholders(_, let refusal):
            switch refusal {
            // Their detail comes from the lease, not from mcp.json.
            case .capabilityUnavailable, .leaseFailed: "its placeholders could not be staged"
            default: "placeholders: " + MCPDisplayedText.field(refusal.message)
            }
        case .secretsUnusable: "rv can't read secrets.json"
        case .signalsUnavailable: "rv can't catch stop signals here"
        }
    }

    /// What fixes it, for the person to do: a command, or the edit and the
    /// command after it.
    public var next: String {
        switch cause {
        case .untrusted, .changedWhileChecked: "rv mcp trust"
        case .trustUnavailable: "sudo rv mcp custodian install"
        case .configurationUnusable: "rv mcp check"
        case .noServers: "rv mcp import"
        case .unknownServer, .blocked: "rv mcp list"
        case .secretUndefined(_, let secret): "\(CommandVocabulary.Alias.secretsAdd.invocation) \(MCPDisplayedText.field(secret))"
        case .secretUnavailable, .secretsUnusable: "rv secrets check"
        case .secretInArguments(_, let found): found.fix
        case .noSandbox(let server):
            "add \"sandbox\": {\"network\": false} to \(MCPDisplayedText.field(server)) in mcp.json, then rv mcp trust"
        case .openNetwork(let server):
            "list the hosts \(MCPDisplayedText.field(server)) needs in sandbox.hosts in mcp.json, then rv mcp trust"
        case .cageUnavailable, .signalsUnavailable: "rv doctor"
        case .placeholders(let server, _):
            "fix \(MCPDisplayedText.field(server))'s placeholders in mcp.json, then rv mcp trust"
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

    /// The cause when every planned connection is refused (the first
    /// one's); nil when any would start.
    public static func cause(
        ofPlanned connections: [MCPUpstreamConnection], configuration: MCPConfiguration
    ) -> Cause? {
        var first: Cause?
        for connection in connections {
            guard case .refused(let server, let refusal) = connection else { return nil }
            guard first == nil else { continue }
            switch refusal {
            case .placeholder(let placeholder): first = cause(server: server, placeholders: placeholder)
            case .secretInArguments(let secret): first = .secretInArguments(server: server, secret: secret)
            case .sandbox:
                // `MCPLaunchPlanner.sealRefusal` refuses one alone only for
                // these two.
                first = configuration.server(named: server)?.sandbox == nil ? .noSandbox(server) : .openNetwork(server)
            }
        }
        return first
    }

    /// The answer to one client line: an error for every request (a
    /// message with a method and an id), nothing for notifications or
    /// responses, a parse error for a line that is not JSON.
    public func answer(_ line: Data) -> JSONValue? {
        guard let message = try? JSONValue.parse(line) else { return Self.parseError }
        guard message.objectValue != nil else { return Self.invalidRequest(id: .null) }
        let id = message["id"].map(Self.echoed) ?? .null
        if let method = message["method"] {
            guard method.stringValue != nil else { return Self.invalidRequest(id: id) }
            // A notification: no id, no answer.
            return message["id"] == nil ? nil : errorResponse(id: id)
        }
        // A response to nothing rv asked: no answer.
        if message["id"] != nil, message["result"] != nil || message["error"] != nil { return nil }
        return Self.invalidRequest(id: id)
    }

    /// The answer to a line that is not JSON, or one over the line cap.
    public static let parseError: JSONValue = .object([
        "jsonrpc": .string("2.0"), "id": .null,
        "error": .object(["code": .int(-32700), "message": .string("Parse error")]),
    ])

    /// The answer to JSON that is neither a request, a notification nor a response.
    static func invalidRequest(id: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .int(-32600), "message": .string("Invalid Request")]),
        ])
    }

    /// The longest request id echoed back; a longer one, or one that is not
    /// a string or number, is answered with a null id.
    public static let maximumIDBytes = 1024

    static func echoed(_ id: JSONValue) -> JSONValue {
        switch id {
        case .string, .number: id.compactText.utf8.count <= maximumIDBytes ? id : .null
        case .null, .bool, .array, .object: .null
        }
    }
}

/// Serves an `MCPServeRefusal` over stdio: every request the client sends
/// gets the refusal as its error, so the host shows the agent why the
/// server is off instead of an empty pipe.
///
/// It starts nothing, resolves nothing and reads no configuration: it only
/// holds the refusal it was given. It is bounded every way: a line over
/// `maximumLineBytes` is dropped whole and answered once as a parse
/// error; it reads at most `maximumLines`
/// lines of any kind (empty ones, notifications and responses included);
/// it stops at EOF, on a failed or stalled write, after `idleSeconds`
/// with no input, and after `totalSeconds` in all however the client
/// trickles bytes.
public enum MCPRefusalResponder {
    public static let maximumLineBytes = 1024 * 1024
    public static let maximumLines = 32
    public static let idleSeconds: Int32 = 30
    public static let totalSeconds: Double = 60
    /// How long one answer may take to write, on a blocking stdout too.
    public static let writeSeconds: Double = 10

    /// Returns how many requests were answered.
    @discardableResult
    public static func serve(
        _ refusal: MCPServeRefusal, input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO,
        idleSeconds: Int32 = idleSeconds, totalSeconds: Double = totalSeconds
    ) -> Int {
        let deadline = Date().addingTimeInterval(totalSeconds)
        var answered = 0
        var lines = 0
        var line: [UInt8] = []
        var overflowing = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        /// False once serving should stop: the line budget is spent or a write failed.
        /// `bytes` nil: a line over the cap, answered once as a parse error.
        func handle(_ bytes: [UInt8]?) -> Bool {
            lines += 1
            var trimmed = bytes ?? []
            if trimmed.last == 0x0D { trimmed.removeLast() }
            let reply: JSONValue? = bytes == nil
                ? MCPServeRefusal.parseError
                : trimmed.isEmpty ? nil : refusal.answer(Data(trimmed))
            if let reply {
                guard writeLine(output, reply.compactText) else { return false }
                answered += 1
            }
            return lines < maximumLines
        }
        reading: while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return answered }
            var poller = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            let wait = min(Int32(idleSeconds) * 1000, Int32(min(remaining * 1000, Double(Int32.max))) + 1)
            let ready = poll(&poller, 1, wait)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return answered }
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(input, base, raw.count)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break reading }
            var start = 0
            for index in 0..<n where buffer[index] == 0x0A {
                if overflowing == false {
                    line += buffer[start..<index]
                }
                // The newline can arrive in the chunk that crosses the cap.
                let dropped = overflowing || line.count > maximumLineBytes
                guard handle(dropped ? nil : line) else { return answered }
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
        // EOF: a last line with no newline.
        if overflowing {
            _ = handle(nil)
        } else if line.isEmpty == false {
            _ = handle(line)
        }
        return answered
    }

    /// One JSON-RPC line, written whole within `writeSeconds`; false when
    /// the reader is gone or stalls. Each write waits for room first and is
    /// at most `PIPE_BUF` bytes, so a blocking stdout cannot hold it past
    /// the deadline either.
    static func writeLine(_ fd: Int32, _ text: String, seconds: Double = writeSeconds) -> Bool {
        let bytes = Array((text + "\n").utf8)
        let deadline = Date().addingTimeInterval(seconds)
        let chunk = 512
        var written = 0
        while written < bytes.count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&poller, 1, Int32(remaining * 1000) + 1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, poller.revents & Int16(POLLOUT) != 0 else { return false }
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base + written, min(chunk, raw.count - written))
            }
            if n < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard n > 0 else { return false }
            written += n
        }
        return true
    }
}

extension MCPServeRefusal {
    /// Why `rv mcp serve --server name` would start nothing, judged from
    /// mcp.json, its integrity and secrets.json alone (nothing is resolved);
    /// nil when serve would start it. It asks the planner's own questions
    /// (`MCPLaunchPlanner.sealRefusal`, `MCPPlaceholderPlanning.refusal`,
    /// `MCPLaunchPlanner.referencedSecrets`, `MCPSandbox.refusesUncaged`)
    /// in the planner's order, so `rv mcp list` cannot drift from serve.
    /// `secrets` nil: secrets.json could not be read, so serve starts nothing.
    public static func cause(
        serving name: String, configuration: MCPConfiguration, integrity: MCPIntegrityStatus,
        secrets: SecretsConfiguration?, requireSandbox: Bool = MCPSandbox.enforced,
        placeholdersSupported: Bool? = nil
    ) -> Cause? {
        let placeholdersSupported = placeholdersSupported ?? MCPPlaceholderLeasing.supportedPlatform
        switch integrity {
        case .unsupportedPlatform: return .trustUnavailable
        case .untrusted: return .untrusted
        case .noConfiguration, .trusted: break
        }
        guard let secrets else { return .secretsUnusable }
        if configuration.isBlocked(name) { return .blocked(name) }
        guard let server = configuration.server(named: name) else { return .unknownServer(name) }
        func undefined(_ names: [String]) -> Cause? {
            names.first { secrets.secret(named: $0) == nil }.map { .secretUndefined(server: name, secret: $0) }
        }
        if let remote = server.remote { return undefined(remote.secretNames) }
        if let secret = MCPLaunchPlanner.argumentSecret(server) {
            return .secretInArguments(server: name, secret: secret)
        }
        if server.placeholders.isEmpty == false {
            if let refusal = MCPPlaceholderPlanning.refusal(
                server, platformSupported: placeholdersSupported, cageEnforced: requireSandbox, secrets: secrets)
            {
                return cause(server: name, placeholders: refusal)
            }
        } else {
            switch MCPLaunchPlanner.sealRefusal(server, configuration: configuration, requireSandbox: requireSandbox) {
            case .refusedAlone?: return server.sandbox == nil ? .noSandbox(name) : .openNetwork(name)
            case .failsPlan?: return .cageUnavailable
            case nil: break
            }
        }
        if let missing = undefined(MCPLaunchPlanner.referencedSecrets(server)) { return missing }
        if MCPSandbox.refusesUncaged(server, enforced: requireSandbox) { return .cageUnavailable }
        return nil
    }
}
