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
    /// Any other audit event (for example a rejected forged grant).
    case event(AuditEvent)
    case log(String)
}

/// How an `ask` call got its approval.
public enum MCPApprovalChannel: String, Sendable, Equatable {
    /// The MCP client showed the user an `elicitation/create` prompt.
    case elicitation
    /// `rv mcp approve` with the user present.
    case local
}

/// One `tools/call` decision, for the `mcp.call` audit event. Argument keys only.
public struct MCPCallRecord: Sendable, Equatable {
    public var server: String
    public var tool: String
    public var decision: MCPToolDecision
    public var approvalID: String?
    public var approvedVia: MCPApprovalChannel?
    public var argumentKeys: [String]
    public var durationMilliseconds: Int?
    public var isError: Bool
    /// The user refused an `ask` call.
    public var declined: Bool
    public var reason: String?

    public init(
        server: String, tool: String, decision: MCPToolDecision, approvalID: String? = nil,
        approvedVia: MCPApprovalChannel? = nil, argumentKeys: [String], durationMilliseconds: Int? = nil,
        isError: Bool, declined: Bool = false, reason: String? = nil
    ) {
        self.server = server
        self.tool = tool
        self.decision = decision
        self.approvalID = approvalID
        self.approvedVia = approvedVia
        self.argumentKeys = argumentKeys
        self.durationMilliseconds = durationMilliseconds
        self.isError = isError
        self.declined = declined
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

    struct Approval {
        var id: String
        var channel: MCPApprovalChannel
    }

    enum Pending {
        case initialize(server: String)
        case list(fanout: Int, server: String)
        case call(client: JSONValue, server: String, tool: String, keys: [String], approval: Approval?, started: Date)
        case cancelled
    }

    struct ListFanout {
        var client: JSONValue
        var remaining: Set<String>
        var tools: [JSONValue]
    }

    /// An `ask` call waiting for the user's answer to an elicitation. The
    /// exact params are kept, so the answer applies to these arguments only.
    struct HeldCall {
        var client: JSONValue
        var server: String
        var tool: String
        var params: JSONObject
        var arguments: JSONValue
        var keys: [String]
        /// The elicitation text the person was shown. Accept runs only when
        /// this text contains the full arguments.
        var shown: String
    }

    /// Unanswered elicitations past this fall back to `rv mcp approve`.
    static let maximumHeld = 64

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
    var held: [String: HeldCall] = [:]
    var clientElicits = false
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
        guard let method = message["method"]?.stringValue else {
            guard let id = message["id"], message["result"] != nil || message["error"] != nil else { return [] }
            return clientResponse(id: id, message)
        }
        guard let id = message["id"] else { return clientNotification(method, message["params"]) }
        switch method {
        case "initialize":
            let requested = message["params"]?["protocolVersion"]?.stringValue ?? ""
            let negotiated = Self.supportedVersions.contains(requested) ? requested : Self.upstreamVersion
            clientElicits = Self.supportsFormElicitation(message["params"]?["capabilities"]?["elicitation"])
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

    /// Accept only when `action` is `accept` and `content.approve` is a JSON
    /// boolean true, or is absent (the schema default). A present non-boolean
    /// (`"false"`, `0`, `null`) is a decline. The held call's arguments are
    /// what runs; the client's content is not forwarded.
    static func elicitationAccepts(_ result: JSONValue?) -> Bool {
        guard result?["action"]?.stringValue == "accept" else { return false }
        guard let approve = result?["content"]?["approve"] else { return true }
        guard case .bool(let value) = approve else { return false }
        return value
    }

    /// An empty `elicitation` object means form mode (2025-06-18); later
    /// revisions list the modes, and rv needs `form`.
    static func supportsFormElicitation(_ capability: JSONValue?) -> Bool {
        guard let object = capability?.objectValue else { return false }
        return object.isEmpty || object["form"] != nil
    }

    /// The client's answer to an `elicitation/create` rv sent.
    mutating func clientResponse(id: JSONValue, _ message: JSONValue) -> [MCPGatewayOutput] {
        guard let key = id.stringValue, let call = held.removeValue(forKey: key) else { return [] }
        if message["error"] != nil {
            return outOfBand(
                client: call.client, server: call.server, tool: call.tool, arguments: call.arguments, keys: call.keys)
        }
        let accepted = Self.elicitationAccepts(message["result"])
        guard accepted else {
            let reason = "declined by the user"
            return [
                .audit(MCPCallRecord(
                    server: call.server, tool: call.tool, decision: .ask, approvalID: key, argumentKeys: call.keys,
                    isError: true, declined: true, reason: reason)),
                .toClient(Self.toolError(
                    id: call.client,
                    "The user declined \(call.server) tool \(call.tool) in rv's approval prompt. Do not retry unless the user asks.")),
            ]
        }
        guard phases[call.server] == .ready else {
            return unavailable(client: call.client, server: call.server, tool: call.tool, decision: .ask, keys: call.keys)
        }
        guard Self.elicitationCovers(call.arguments, shown: call.shown) else {
            return argumentsNotShown(client: call.client, server: call.server, tool: call.tool, keys: call.keys)
        }
        let approval = Approval(id: key, channel: .elicitation)
        let upstreamID = allocate(.call(
            client: call.client, server: call.server, tool: call.tool, keys: call.keys, approval: approval, started: clock()))
        return [.toUpstream(server: call.server, message: Self.request(
            id: .int(upstreamID), method: "tools/call", params: .object(call.params)))]
    }

    mutating func clientNotification(_ method: String, _ params: JSONValue?) -> [MCPGatewayOutput] {
        guard method == "notifications/cancelled", let target = params?["requestId"] else { return [] }
        if let key = held.first(where: { $0.value.client == target })?.key {
            held[key] = nil
            return [.toClient(Self.notification("notifications/cancelled", .object([
                "requestId": .string(key), "reason": .string("the tool call was cancelled"),
            ])))]
        }
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
        let decision = configuration.decision(server: upstream.definition, tool: tool)
        if decision == .deny {
            let reason = "rv policy denies \(server) tool \(tool)"
            return [
                .audit(MCPCallRecord(server: server, tool: tool, decision: .deny, argumentKeys: keys, isError: true, reason: reason)),
                .toClient(Self.toolError(id: client, "\(reason). Do not retry; ask the user if you need it.")),
            ]
        }
        guard phases[server] == .ready else {
            return unavailable(client: client, server: server, tool: tool, decision: decision, keys: keys)
        }
        var forwarded = params?.objectValue ?? JSONObject()
        forwarded["name"] = .string(tool)
        var approval: Approval?
        var outputs: [MCPGatewayOutput] = []
        if decision == .ask {
            let hash = arguments.canonicalHash
            switch approvals.consumeGrant(server, tool, hash, keys) {
            case .granted(let id):
                approval = Approval(id: id, channel: .local)
            case .forged(let id):
                outputs.append(.event(AuditEvent(
                    time: clock(), kind: .mcpApproval, decision: .denied, subject: "\(server)/\(tool)",
                    reason: "forged grant rejected", source: "mcp-gateway", detail: ["approval": id])))
                outputs.append(.log("rejected approval \(id) for \(server) tool \(tool): its grant was not signed by rv"))
            case .none:
                break
            }
            if approval == nil {
                return outputs + askUser(client: client, server: server, tool: tool, params: forwarded, arguments: arguments, keys: keys)
            }
        }
        let id = allocate(.call(client: client, server: server, tool: tool, keys: keys, approval: approval, started: clock()))
        return outputs + [.toUpstream(server: server, message: Self.request(id: .int(id), method: "tools/call", params: .object(forwarded)))]
    }

    /// Elicitation when the client can show it; otherwise a pending request
    /// the user approves out of band with `rv mcp approve`.
    mutating func askUser(
        client: JSONValue, server: String, tool: String, params: JSONObject, arguments: JSONValue, keys: [String]
    ) -> [MCPGatewayOutput] {
        if clientElicits, held.count < Self.maximumHeld {
            let message = Self.elicitationMessage(server: server, tool: tool, arguments: arguments)
            guard Self.elicitationCovers(arguments, shown: message) else {
                return argumentsNotShown(client: client, server: server, tool: tool, keys: keys)
            }
            let key = "rv-approval-\(nextID)"
            nextID += 1
            held[key] = HeldCall(
                client: client, server: server, tool: tool, params: params, arguments: arguments, keys: keys, shown: message)
            return [
                .audit(MCPCallRecord(
                    server: server, tool: tool, decision: .ask, approvalID: key, argumentKeys: keys, isError: false,
                    reason: "awaiting approval in the client")),
                .toClient(Self.request(id: .string(key), method: "elicitation/create", params: .object([
                    "message": .string(message),
                    "requestedSchema": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "approve": .object([
                                "type": .string("boolean"),
                                "title": .string("Allow this call once"),
                                "description": .string("rv runs only this call, with exactly these arguments."),
                                "default": .bool(true),
                            ])
                        ]),
                        "required": .array([.string("approve")]),
                    ]),
                ]))),
            ]
        }
        return outOfBand(client: client, server: server, tool: tool, arguments: arguments, keys: keys)
    }

    func outOfBand(
        client: JSONValue, server: String, tool: String, arguments: JSONValue, keys: [String]
    ) -> [MCPGatewayOutput] {
        guard let ticket = approvals.request(server, tool, arguments.canonicalHash, keys) else {
            let reason = "rv could not record an approval request"
            return [
                .audit(MCPCallRecord(server: server, tool: tool, decision: .ask, argumentKeys: keys, isError: true, reason: reason)),
                .toClient(Self.toolError(id: client, reason)),
            ]
        }
        let text = "rv paused this call: \(server) tool \(tool) needs the user's approval. "
            + "Ask the user to run `rv mcp approve \(ticket.id)` in their own terminal "
            + "(or `rv mcp approve \(ticket.id) --always`), then call the tool again with the same arguments."
        var outputs: [MCPGatewayOutput] = [
            .audit(MCPCallRecord(
                server: server, tool: tool, decision: .ask, approvalID: ticket.id, argumentKeys: keys, isError: true,
                reason: "awaiting approval")),
            .toClient(Self.toolError(id: client, text)),
        ]
        if ticket.code != nil {
            outputs.append(.log("approval \(ticket.id) for \(server) tool \(tool) is waiting for the user"))
        }
        return outputs
    }

    static func elicitationMessage(server: String, tool: String, arguments: JSONValue) -> String {
        "rv: allow MCP server \(server) to run tool \(tool)?\nArguments: \(arguments.canonicalText)"
    }

    /// True only when `shown` carries the arguments that would run, in full.
    /// A prefix, with or without an ellipsis, is not enough.
    static func elicitationCovers(_ arguments: JSONValue, shown: String) -> Bool {
        let marker = "\nArguments: "
        guard let range = shown.range(of: marker) else { return false }
        return shown[range.upperBound...] == arguments.canonicalText
    }

    func argumentsNotShown(
        client: JSONValue, server: String, tool: String, keys: [String]
    ) -> [MCPGatewayOutput] {
        let reason = "approval prompt did not include the full arguments"
        return [
            .audit(MCPCallRecord(
                server: server, tool: tool, decision: .ask, argumentKeys: keys, isError: true, reason: reason)),
            .toClient(Self.toolError(
                id: client,
                "rv refused \(server) tool \(tool): the approval prompt did not include the full arguments. The call was not run.")),
        ]
    }

    func unavailable(
        client: JSONValue, server: String, tool: String, decision: MCPToolDecision, keys: [String]
    ) -> [MCPGatewayOutput] {
        let reason: String
        if case .failed(let why)? = phases[server] { reason = why } else { reason = "not ready" }
        return [
            .audit(MCPCallRecord(
                server: server, tool: tool, decision: decision == .ask ? .ask : .allow, argumentKeys: keys, isError: true,
                reason: "upstream unavailable: \(reason)")),
            .toClient(Self.error(id: client, code: -32603, message: "MCP server \(server) is unavailable: \(reason)")),
        ]
    }

    /// Longest configured `<server>__` prefix. A tie (two exposed names that
    /// cannot be told apart) or no match is an unknown tool.
    func route(_ exposed: String) -> (server: String, tool: String)? {
        guard prefixesTools else { return order.first.map { ($0, exposed) } }
        let matches: [(server: String, tool: String)] = order.compactMap { server in
            let prefix = server + Self.separator
            guard exposed.hasPrefix(prefix) else { return nil }
            let tool = String(exposed.dropFirst(prefix.count))
            guard tool.isEmpty == false, upstreams[server] != nil else { return nil }
            return (server, tool)
        }
        guard let longest = matches.map(\.server.count).max() else { return nil }
        let best = matches.filter { $0.server.count == longest }
        guard best.count == 1 else { return nil }
        return best[0]
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
            let raw = message["error"]?["message"]?.stringValue ?? "initialize failed"
            let reason = scrubText(raw, for: server)
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
                    server: server, tool: tool, decision: approval == nil ? .allow : .ask, approvalID: approval?.id,
                    approvedVia: approval?.channel, argumentKeys: keys, durationMilliseconds: max(0, duration),
                    isError: isError)),
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
        if prefixesTools {
            let exposedName = upstream.definition.name + Self.separator + name
            // A shorter server's tool must not be listed under a name the
            // longest matching server owns; that call would not reach it.
            guard route(exposedName)?.server == upstream.definition.name else { return nil }
            object["name"] = .string(exposedName)
        }
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
                    server: server, tool: tool, decision: approval == nil ? .allow : .ask, approvalID: approval?.id,
                    approvedVia: approval?.channel, argumentKeys: keys, isError: true, reason: "upstream exited")))
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

    func scrubText(_ text: String, for server: String) -> String {
        guard let secrets = upstreams[server]?.secretValues, secrets.isEmpty == false else { return text }
        return Self.scrubText(text, secrets: secrets)
    }

    static func scrub(_ value: JSONValue, secrets: [(name: String, value: String)]) -> JSONValue {
        switch value {
        case .string(let text):
            return .string(scrubText(text, secrets: secrets))
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

    /// Longer secrets first, so a short value that is a prefix of a longer one
    /// cannot leave the tail. Raw and JSON-escaped spellings are both removed,
    /// including values shorter than 4 characters. Empty values are skipped.
    static func scrubText(_ text: String, secrets: [(name: String, value: String)]) -> String {
        let ordered = secrets.filter { $0.value.isEmpty == false }.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
            return lhs.name < rhs.name
        }
        var text = text
        for secret in ordered {
            let raw = secret.value
            let escaped = JSONValue.escapedContent(raw)
            let forms = escaped == raw ? [raw] : [escaped, raw].sorted { $0.count > $1.count }
            let replacement = "[redacted:\(secret.name)]"
            for form in forms where text.contains(form) {
                text = text.replacingOccurrences(of: form, with: replacement)
            }
        }
        return text
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
    /// is `allowed`; one that stopped for approval is `pending`; one the
    /// user refused is `denied`.
    public func auditEvent(time: Date = Date()) -> AuditEvent {
        let audited: AuditDecision
        switch decision {
        case .allow: audited = .allowed
        case .deny: audited = .denied
        case .ask: audited = declined ? .denied : durationMilliseconds == nil ? .pending : .allowed
        }
        var detail = [
            "server": server,
            "tool": tool,
            "policy": decision.rawValue,
            "argumentKeys": argumentKeys.joined(separator: ","),
            "isError": isError ? "true" : "false",
        ]
        if let approvalID { detail["approval"] = approvalID }
        if let approvedVia { detail["approvedVia"] = approvedVia.rawValue }
        if let durationMilliseconds { detail["durationMs"] = String(durationMilliseconds) }
        return AuditEvent(
            time: time, kind: .mcpCall, decision: audited, subject: "\(server)/\(tool)", reason: reason,
            source: "mcp-gateway", detail: detail)
    }
}
