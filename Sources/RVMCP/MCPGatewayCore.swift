import Foundation
import RVHistory

public enum MCPGatewayInput: Sendable, Equatable {
    case client(JSONValue)
    /// A line from the client that is not JSON.
    case clientUnparseable
    case upstream(server: String, message: JSONValue)
    case upstreamExited(server: String)
}

public enum MCPGatewayOutput: Sendable, Equatable {
    case toClient(JSONValue)
    case toUpstream(server: String, message: JSONValue)
    case audit(MCPCallRecord)
    case log(String)
}

/// One `tools/call` decision, for the `mcp.call` audit event. Argument keys only.
public struct MCPCallRecord: Sendable, Equatable {
    public var server: String
    public var tool: String
    public var decision: MCPToolDecision
    public var approvalID: String?
    public var argumentKeys: [String]
    public var durationMilliseconds: Int?
    public var isError: Bool
    public var reason: String?

    public init(
        server: String, tool: String, decision: MCPToolDecision, approvalID: String? = nil, argumentKeys: [String],
        durationMilliseconds: Int? = nil, isError: Bool, reason: String? = nil
    ) {
        self.server = server
        self.tool = tool
        self.decision = decision
        self.approvalID = approvalID
        self.argumentKeys = argumentKeys
        self.durationMilliseconds = durationMilliseconds
        self.isError = isError
        self.reason = reason
    }
}

/// The MCP gateway as a state machine: messages in, messages and audit out.
/// No I/O, so every protocol rule is unit-testable. `MCPGatewayRuntime`
/// supplies processes and pipes.
public struct MCPGatewayCore {
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let upstreamVersion = "2025-06-18"
    public static let separator = "__"

    public struct Upstream: Sendable {
        public var definition: MCPServerDefinition
        /// Secret name → value given to this upstream; scrubbed from everything it returns.
        public var secretValues: [(name: String, value: String)]

        public init(definition: MCPServerDefinition, secretValues: [(name: String, value: String)] = []) {
            self.definition = definition
            self.secretValues = secretValues
        }
    }

    enum UpstreamPhase: Equatable {
        case starting
        case ready
        case failed(String)
    }

    enum Pending {
        case initialize(server: String)
        case list(fanout: Int, server: String)
        case call(client: JSONValue, server: String, tool: String, keys: [String], approval: String?, started: Date)
        case cancelled
    }

    struct ListFanout {
        var client: JSONValue
        var remaining: Set<String>
        var tools: [JSONValue]
    }

    let configuration: MCPConfiguration
    let upstreams: [String: Upstream]
    let order: [String]
    let approvals: MCPApprovalGate
    let clock: () -> Date
    let version: String

    var phases: [String: UpstreamPhase] = [:]
    var pending: [Int: Pending] = [:]
    var fanouts: [Int: ListFanout] = [:]
    var waiting: [JSONValue] = []
    var nextID = 1

    public init(
        configuration: MCPConfiguration,
        upstreams: [Upstream],
        approvals: MCPApprovalGate,
        version: String = "1",
        clock: @escaping () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.upstreams = Dictionary(upstreams.map { ($0.definition.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.order = upstreams.map(\.definition.name)
        self.approvals = approvals
        self.clock = clock
        self.version = version
    }

    var prefixesTools: Bool { order.count > 1 }

    var allSettled: Bool { phases.values.allSatisfy { $0 != .starting } }

    /// Initialize every upstream.
    public mutating func start() -> [MCPGatewayOutput] {
        order.map { server in
            phases[server] = .starting
            let id = allocate(.initialize(server: server))
            return .toUpstream(server: server, message: Self.request(id: .int(id), method: "initialize", params: .object([
                "protocolVersion": .string(Self.upstreamVersion),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("rv-mcp-gateway"), "version": .string(version)]),
            ])))
        }
    }

    public mutating func handle(_ input: MCPGatewayInput) -> [MCPGatewayOutput] {
        switch input {
        case .client(let message): clientMessage(message)
        case .clientUnparseable: [.toClient(Self.error(id: .null, code: -32700, message: "Parse error"))]
        case .upstream(let server, let message): upstreamMessage(server, message)
        case .upstreamExited(let server): upstreamExited(server)
        }
    }

    // MARK: Client side

    mutating func clientMessage(_ message: JSONValue) -> [MCPGatewayOutput] {
        guard message.objectValue != nil, message["jsonrpc"]?.stringValue == "2.0" else {
            return [.toClient(Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid Request"))]
        }
        guard let method = message["method"]?.stringValue else { return [] }
        guard let id = message["id"] else { return clientNotification(method, message["params"]) }
        switch method {
        case "initialize":
            let requested = message["params"]?["protocolVersion"]?.stringValue ?? ""
            let negotiated = Self.supportedVersions.contains(requested) ? requested : Self.upstreamVersion
            return [.toClient(Self.result(id: id, .object([
                "protocolVersion": .string(negotiated),
                "capabilities": .object(["tools": .object(["listChanged": .bool(true)])]),
                "serverInfo": .object(["name": .string("rv"), "version": .string(version)]),
                "instructions": .string(
                    "Tools are served through rv. Some calls need the user's approval; follow the tool error when that happens."),
            ])))]
        case "ping":
            return [.toClient(Self.result(id: id, .object([:])))]
        case "tools/list", "tools/call":
            guard allSettled else {
                waiting.append(message)
                return []
            }
            return method == "tools/list" ? listTools(client: id) : callTool(client: id, params: message["params"])
        default:
            return [.toClient(Self.error(id: id, code: -32601, message: "Method not found: \(method)"))]
        }
    }

    mutating func clientNotification(_ method: String, _ params: JSONValue?) -> [MCPGatewayOutput] {
        guard method == "notifications/cancelled", let target = params?["requestId"] else { return [] }
        for (id, entry) in pending {
            guard case .call(let client, let server, _, _, _, _) = entry, client == target else { continue }
            pending[id] = .cancelled
            var forwarded = JSONObject()
            forwarded["requestId"] = .int(id)
            if let reason = params?["reason"] { forwarded["reason"] = reason }
            return [.toUpstream(server: server, message: Self.notification("notifications/cancelled", .object(forwarded)))]
        }
        return []
    }

    mutating func listTools(client: JSONValue) -> [MCPGatewayOutput] {
        let ready = order.filter { phases[$0] == .ready }
        guard ready.isEmpty == false else {
            return [.toClient(Self.result(id: client, .object(["tools": .array([])])))]
        }
        let fanout = nextID
        nextID += 1
        fanouts[fanout] = ListFanout(client: client, remaining: Set(ready), tools: [])
        return ready.map { server in
            let id = allocate(.list(fanout: fanout, server: server))
            return .toUpstream(server: server, message: Self.request(id: .int(id), method: "tools/list", params: nil))
        }
    }

    mutating func callTool(client: JSONValue, params: JSONValue?) -> [MCPGatewayOutput] {
        guard let exposed = params?["name"]?.stringValue else {
            return [.toClient(Self.error(id: client, code: -32602, message: "tools/call needs a name"))]
        }
        guard let (server, tool) = route(exposed), let upstream = upstreams[server] else {
            return [.toClient(Self.error(id: client, code: -32602, message: "Unknown tool: \(exposed)"))]
        }
        let arguments = params?["arguments"] ?? .object([:])
        let keys = arguments.objectValue?.keys.sorted() ?? []
        var approval: String?
        switch configuration.decision(server: upstream.definition, tool: tool) {
        case .deny:
            let reason = "rv policy denies \(server) tool \(tool)"
            return [
                .audit(MCPCallRecord(server: server, tool: tool, decision: .deny, argumentKeys: keys, isError: true, reason: reason)),
                .toClient(Self.toolError(id: client, "\(reason). Do not retry; ask the user if you need it.")),
            ]
        case .ask:
            let hash = arguments.canonicalHash
            if let granted = approvals.consumeGrant(server, tool, hash) {
                approval = granted
                break
            }
            guard let id = approvals.request(server, tool, hash, keys) else {
                let reason = "rv could not record an approval request"
                return [
                    .audit(MCPCallRecord(server: server, tool: tool, decision: .ask, argumentKeys: keys, isError: true, reason: reason)),
                    .toClient(Self.toolError(id: client, reason)),
                ]
            }
            let text = "rv paused this call: \(server) tool \(tool) needs the user's approval. "
                + "Ask the user to run `rv mcp approve \(id)` (or `rv mcp approve \(id) --always`), "
                + "then call the tool again with the same arguments."
            return [
                .audit(MCPCallRecord(
                    server: server, tool: tool, decision: .ask, approvalID: id, argumentKeys: keys, isError: true,
                    reason: "awaiting approval")),
                .toClient(Self.toolError(id: client, text)),
            ]
        case .allow:
            break
        }
        guard phases[server] == .ready else {
            let reason: String
            if case .failed(let why)? = phases[server] { reason = why } else { reason = "not ready" }
            return [
                .audit(MCPCallRecord(
                    server: server, tool: tool, decision: approval == nil ? .allow : .ask, approvalID: approval,
                    argumentKeys: keys, isError: true, reason: "upstream unavailable: \(reason)")),
                .toClient(Self.error(id: client, code: -32603, message: "MCP server \(server) is unavailable: \(reason)")),
            ]
        }
        var forwarded = params?.objectValue ?? JSONObject()
        forwarded["name"] = .string(tool)
        let id = allocate(.call(client: client, server: server, tool: tool, keys: keys, approval: approval, started: clock()))
        return [.toUpstream(server: server, message: Self.request(id: .int(id), method: "tools/call", params: .object(forwarded)))]
    }

    func route(_ exposed: String) -> (server: String, tool: String)? {
        guard prefixesTools else { return order.first.map { ($0, exposed) } }
        guard let range = exposed.range(of: Self.separator) else { return nil }
        let server = String(exposed[..<range.lowerBound])
        let tool = String(exposed[range.upperBound...])
        guard upstreams[server] != nil, tool.isEmpty == false else { return nil }
        return (server, tool)
    }

    // MARK: Upstream side

    mutating func upstreamMessage(_ server: String, _ message: JSONValue) -> [MCPGatewayOutput] {
        guard upstreams[server] != nil else { return [] }
        if let method = message["method"]?.stringValue {
            if let id = message["id"] {
                let reply = method == "ping"
                    ? Self.result(id: id, .object([:]))
                    : Self.error(id: id, code: -32601, message: "rv gateway does not support \(method)")
                return [.toUpstream(server: server, message: reply)]
            }
            switch method {
            case "notifications/tools/list_changed":
                return [.toClient(Self.notification(method, nil))]
            case "notifications/progress":
                return [.toClient(scrub(message, for: server))]
            default:
                return []
            }
        }
        guard let id = message["id"]?.intValue, let entry = pending.removeValue(forKey: id) else { return [] }
        switch entry {
        case .initialize:
            if message["result"]?.objectValue != nil {
                phases[server] = .ready
                return [.toUpstream(server: server, message: Self.notification("notifications/initialized", nil))]
                    + releaseWaiting()
            }
            let reason = message["error"]?["message"]?.stringValue ?? "initialize failed"
            phases[server] = .failed(reason)
            return [.log("MCP server \(server) failed to initialize: \(reason)")] + releaseWaiting()
        case .list(let fanout, _):
            return listPage(fanout: fanout, server: server, message: message)
        case .call(let client, _, let tool, let keys, let approval, let started):
            let isError = message["error"] != nil || message["result"]?["isError"]?.boolValue == true
            var reply = scrub(message, for: server).objectValue ?? JSONObject()
            reply["id"] = client
            let duration = Int((clock().timeIntervalSince(started) * 1000).rounded())
            return [
                .audit(MCPCallRecord(
                    server: server, tool: tool, decision: approval == nil ? .allow : .ask, approvalID: approval,
                    argumentKeys: keys, durationMilliseconds: max(0, duration), isError: isError)),
                .toClient(.object(reply)),
            ]
        case .cancelled:
            return []
        }
    }

    mutating func listPage(fanout: Int, server: String, message: JSONValue) -> [MCPGatewayOutput] {
        guard var state = fanouts[fanout] else { return [] }
        var outputs: [MCPGatewayOutput] = []
        if let upstream = upstreams[server], let tools = message["result"]?["tools"]?.arrayValue {
            state.tools += tools.compactMap { exposedTool($0, upstream: upstream) }
            if let cursor = message["result"]?["nextCursor"]?.stringValue, cursor.isEmpty == false {
                fanouts[fanout] = state
                let id = allocate(.list(fanout: fanout, server: server))
                return [.toUpstream(server: server, message: Self.request(
                    id: .int(id), method: "tools/list", params: .object(["cursor": .string(cursor)])))]
            }
        } else {
            outputs.append(.log("MCP server \(server) did not list tools"))
        }
        state.remaining.remove(server)
        guard state.remaining.isEmpty else {
            fanouts[fanout] = state
            return outputs
        }
        fanouts[fanout] = nil
        return outputs + [.toClient(Self.result(id: state.client, .object(["tools": .array(state.tools)])))]
    }

    /// Denied tools are hidden; `ask` tools say so in their description.
    func exposedTool(_ tool: JSONValue, upstream: Upstream) -> JSONValue? {
        guard var object = scrub(tool, for: upstream.definition.name).objectValue, let name = object["name"]?.stringValue else {
            return nil
        }
        switch configuration.decision(server: upstream.definition, tool: name) {
        case .deny:
            return nil
        case .ask:
            let description = object["description"]?.stringValue ?? ""
            object["description"] = .string("[rv: needs the user's approval] " + description)
        case .allow:
            break
        }
        if prefixesTools { object["name"] = .string(upstream.definition.name + Self.separator + name) }
        return .object(object)
    }

    mutating func upstreamExited(_ server: String) -> [MCPGatewayOutput] {
        guard upstreams[server] != nil else { return [] }
        let reason = "process exited"
        let wasStarting = phases[server] == .starting
        phases[server] = .failed(reason)
        var outputs: [MCPGatewayOutput] = [.log("MCP server \(server) exited")]
        for (id, entry) in pending.sorted(by: { $0.key < $1.key }) {
            switch entry {
            case .initialize(let owner) where owner == server:
                pending[id] = nil
            case .list(let fanout, let owner) where owner == server:
                pending[id] = nil
                outputs += listPage(fanout: fanout, server: server, message: .null)
            case .call(let client, let owner, let tool, let keys, let approval, _) where owner == server:
                pending[id] = nil
                outputs.append(.audit(MCPCallRecord(
                    server: server, tool: tool, decision: approval == nil ? .allow : .ask, approvalID: approval,
                    argumentKeys: keys, isError: true, reason: "upstream exited")))
                outputs.append(.toClient(Self.error(id: client, code: -32603, message: "MCP server \(server) exited")))
            default:
                continue
            }
        }
        return wasStarting ? outputs + releaseWaiting() : outputs
    }

    mutating func releaseWaiting() -> [MCPGatewayOutput] {
        guard allSettled, waiting.isEmpty == false else { return [] }
        let queued = waiting
        waiting = []
        return queued.flatMap { clientMessage($0) }
    }

    // MARK: Helpers

    mutating func allocate(_ entry: Pending) -> Int {
        let id = nextID
        nextID += 1
        pending[id] = entry
        return id
    }

    func scrub(_ value: JSONValue, for server: String) -> JSONValue {
        guard let secrets = upstreams[server]?.secretValues, secrets.isEmpty == false else { return value }
        return Self.scrub(value, secrets: secrets)
    }

    static func scrub(_ value: JSONValue, secrets: [(name: String, value: String)]) -> JSONValue {
        switch value {
        case .string(var text):
            for secret in secrets where secret.value.count >= 4 && text.contains(secret.value) {
                text = text.replacingOccurrences(of: secret.value, with: "[redacted:\(secret.name)]")
            }
            return .string(text)
        case .array(let items):
            return .array(items.map { scrub($0, secrets: secrets) })
        case .object(let object):
            var scrubbed = JSONObject()
            for (key, item) in object.entries { scrubbed[key] = scrub(item, secrets: secrets) }
            return .object(scrubbed)
        default:
            return value
        }
    }

    static func request(id: JSONValue, method: String, params: JSONValue?) -> JSONValue {
        var object = JSONObject()
        object["jsonrpc"] = .string("2.0")
        object["id"] = id
        object["method"] = .string(method)
        if let params { object["params"] = params }
        return .object(object)
    }

    static func notification(_ method: String, _ params: JSONValue?) -> JSONValue {
        var object = JSONObject()
        object["jsonrpc"] = .string("2.0")
        object["method"] = .string(method)
        if let params { object["params"] = params }
        return .object(object)
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .int(code), "message": .string(message)]),
        ])
    }

    static func toolError(id: JSONValue, _ text: String) -> JSONValue {
        result(id: id, .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(true),
        ]))
    }
}

extension MCPCallRecord {
    /// The unified `mcp.call` audit event. An `ask` call that ran on a grant
    /// is `allowed`; one that stopped for approval is `pending`.
    public func auditEvent(time: Date = Date()) -> AuditEvent {
        let audited: AuditDecision
        switch decision {
        case .allow: audited = .allowed
        case .deny: audited = .denied
        case .ask: audited = durationMilliseconds == nil ? .pending : .allowed
        }
        var detail = [
            "server": server,
            "tool": tool,
            "policy": decision.rawValue,
            "argumentKeys": argumentKeys.joined(separator: ","),
            "isError": isError ? "true" : "false",
        ]
        if let approvalID { detail["approval"] = approvalID }
        if let durationMilliseconds { detail["durationMs"] = String(durationMilliseconds) }
        return AuditEvent(
            time: time, kind: .mcpCall, decision: audited, subject: "\(server)/\(tool)", reason: reason,
            source: "mcp-gateway", detail: detail)
    }
}
