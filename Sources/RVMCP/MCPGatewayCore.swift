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

        /// The upstream that owns this request; nil once cancelled. A reply
        /// from any other upstream must not consume the entry.
        var owner: String? {
            switch self {
            case .initialize(let server), .list(_, let server), .call(_, let server, _, _, _, _): server
            case .cancelled: nil
            }
        }
    }

    struct ListFanout {
        var client: JSONValue
        var remaining: Set<String>
        var tools: [JSONValue]
        /// Set when the listing answers `rv_search_tools` instead of `tools/list`.
        var search: Search?
        /// `server\0cursor` pairs already followed; a repeat ends that server's pages.
        var seenCursors: Set<String> = []
        /// Pages fetched per server; capped so a cycling upstream cannot page forever.
        var pages: [String: Int] = [:]
    }

    /// Pagination bounds for one `tools/list` fanout.
    static let maximumListPagesPerServer = 64
    static let maximumListedTools = 4096

    struct Search {
        var terms: [String]
        var limit: Int
    }

    static let searchToolName = "rv_search_tools"
    static let callToolName = "rv_call_tool"
    static let searchLimits = (default: 10, maximum: 50)

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
        var heldAt: Date
    }

    static let argumentPreviewLimit = 600
    /// Unanswered elicitations past this fall back to `rv mcp approve`.
    static let maximumHeld = 64
    /// Longest arguments text an elicitation prompt may carry. Past this a
    /// client UI cannot be trusted to show every byte the user would be
    /// approving, so the call is refused instead of prompted.
    static let maximumElicitationArguments = 4096
    /// An unanswered prompt older than this fails closed on the next message.
    static let heldLifetime: TimeInterval = 300

    let configuration: MCPConfiguration
    var upstreams: [String: Upstream]
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

    /// A value the upstream holds from now on (a refreshed OAuth token), scrubbed like the rest.
    public mutating func addSecret(server: String, name: String, value: String) {
        guard value.isEmpty == false, upstreams[server]?.secretValues.contains(where: { $0.value == value }) == false else { return }
        upstreams[server]?.secretValues.append((name: name, value: value))
    }

    static func oauthSecrets(_ tokens: MCPOAuthTokens) -> [(name: String, value: String)] {
        [(name: "OAUTH_ACCESS_TOKEN", value: tokens.accessToken)]
            + (tokens.refreshToken.map { [(name: "OAUTH_REFRESH_TOKEN", value: $0)] } ?? [])
    }

    var prefixesTools: Bool { order.count > 1 }
    var searchMode: Bool { configuration.toolMode == .search }

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
        // An elicitation answer dispatches before expiry runs: on an idle
        // gateway the user's own (possibly late) answer is the next input,
        // and expiring first would drop it silently.
        if case .client(let message) = input, message["method"] == nil,
            let key = message["id"]?.stringValue, held[key] != nil {
            return clientMessage(message) + expireHeld()
        }
        var outputs = expireHeld()
        switch input {
        case .client(let message): outputs += clientMessage(message)
        case .clientUnparseable: outputs.append(.toClient(Self.error(id: .null, code: -32700, message: "Parse error")))
        case .upstream(let server, let message): outputs += upstreamMessage(server, message)
        case .upstreamExited(let server): outputs += upstreamExited(server)
        }
        return outputs
    }

    /// Fails held elicitations nobody answered in time, so prompts cannot
    /// pin their arguments — or the 64 slots — for the whole session.
    mutating func expireHeld() -> [MCPGatewayOutput] {
        let cutoff = clock().addingTimeInterval(-Self.heldLifetime)
        let expired = held.filter { $0.value.heldAt < cutoff }.sorted { $0.key < $1.key }
        guard expired.isEmpty == false else { return [] }
        var outputs: [MCPGatewayOutput] = []
        for (key, call) in expired {
            held[key] = nil
            outputs.append(.audit(MCPCallRecord(
                server: call.server, tool: call.tool, decision: .ask, approvalID: key, argumentKeys: call.keys,
                isError: true, declined: true, reason: "approval prompt was not answered in time")))
            outputs.append(.toClient(Self.notification("notifications/cancelled", .object([
                "requestId": .string(key), "reason": .string("the approval prompt was not answered in time"),
            ]))))
            outputs.append(.toClient(Self.toolError(
                id: call.client,
                "rv's approval prompt for \(MCPDisplayedText.field(call.server)) tool \(MCPDisplayedText.field(call.tool)) was not answered in time; the call was not run.")))
        }
        return outputs
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
            return [.toClient(Self.error(
                id: id, code: -32601, message: "Method not found: \(MCPDisplayedText.field(method))"))]
        }
    }

    /// Accept only when `action` is `accept` and `content.approve` is
    /// explicitly the JSON boolean true. An absent or non-boolean approve
    /// (`"false"`, `0`, `null`, no content at all) is a decline: an
    /// auto-answered or malformed response must not run the call. The held
    /// call's arguments are what runs; the client's content is not forwarded.
    static func elicitationAccepts(_ result: JSONValue?) -> Bool {
        guard result?["action"]?.stringValue == "accept" else { return false }
        guard let approve = result?["content"]?["approve"], case .bool(let value) = approve else { return false }
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
        if let error = message["error"] {
            // Only "method not found" means the client cannot show prompts at
            // all, so only that falls back to `rv mcp approve`. Any other
            // error (dismissed prompt, client failure) refuses: re-asking on
            // a channel that shows less would turn a no into a second try.
            guard error["code"]?.intValue == -32601 else {
                let reason = "the approval prompt failed in the client"
                return [
                    .audit(MCPCallRecord(
                        server: call.server, tool: call.tool, decision: .ask, approvalID: key, argumentKeys: call.keys,
                        isError: true, declined: true, reason: reason)),
                    .toClient(Self.toolError(
                        id: call.client,
                        "rv could not get an answer to its approval prompt for \(MCPDisplayedText.field(call.server)) tool \(MCPDisplayedText.field(call.tool)); the call was not run. Do not retry unless the user asks.")),
                ]
            }
            return outOfBand(
                client: call.client, server: call.server, tool: call.tool, arguments: call.arguments, keys: call.keys)
        }
        let accepted = Self.elicitationAccepts(message["result"])
        guard accepted else {
            let reason = "declined by the user"
            let shownServer = MCPDisplayedText.field(call.server)
            let shownTool = MCPDisplayedText.field(call.tool)
            return [
                .audit(MCPCallRecord(
                    server: call.server, tool: call.tool, decision: .ask, approvalID: key, argumentKeys: call.keys,
                    isError: true, declined: true, reason: reason)),
                .toClient(Self.toolError(
                    id: call.client,
                    "The user declined \(shownServer) tool \(shownTool) in rv's approval prompt. Do not retry unless the user asks.")),
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
        if searchMode { return [.toClient(Self.result(id: client, .object(["tools": .array(Self.metaTools)])))] }
        return fanOutList(client: client, search: nil)
    }

    mutating func fanOutList(client: JSONValue, search: Search?) -> [MCPGatewayOutput] {
        let ready = order.filter { phases[$0] == .ready }
        guard ready.isEmpty == false else {
            let empty = JSONValue.array([])
            return [.toClient(search.map { Self.searchResult(id: client, tools: [], search: $0) }
                ?? Self.result(id: client, .object(["tools": empty])))]
        }
        let fanout = nextID
        nextID += 1
        fanouts[fanout] = ListFanout(client: client, remaining: Set(ready), tools: [], search: search)
        return ready.map { server in
            let id = allocate(.list(fanout: fanout, server: server))
            return .toUpstream(server: server, message: Self.request(id: .int(id), method: "tools/list", params: nil))
        }
    }

    mutating func callTool(client: JSONValue, params: JSONValue?) -> [MCPGatewayOutput] {
        guard let exposed = params?["name"]?.stringValue else {
            return [.toClient(Self.error(id: client, code: -32602, message: "tools/call needs a name"))]
        }
        if searchMode, exposed == Self.searchToolName {
            let arguments = params?["arguments"]
            let terms = (arguments?["query"]?.stringValue ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            let limit = min(max(arguments?["limit"]?.intValue ?? Self.searchLimits.default, 1), Self.searchLimits.maximum)
            return fanOutList(client: client, search: Search(terms: terms, limit: limit))
        }
        if searchMode, exposed == Self.callToolName {
            let wrapped = params?["arguments"]
            guard let target = wrapped?["name"]?.stringValue, target != Self.callToolName, target != Self.searchToolName else {
                return [.toClient(Self.toolError(id: client, "rv_call_tool needs the name of a tool from rv_search_tools"))]
            }
            let arguments = wrapped?["arguments"] ?? .object([:])
            guard arguments.objectValue != nil else {
                return [.toClient(Self.toolError(id: client, "rv_call_tool arguments must be an object"))]
            }
            var unwrapped = params?.objectValue ?? JSONObject()
            unwrapped["name"] = .string(target)
            unwrapped["arguments"] = arguments
            return callTool(client: client, params: .object(unwrapped))
        }
        // Search mode is presentation-only: a direct call by exposed name takes
        // the same policy, approval, and audit path as one via rv_call_tool.
        guard let (server, tool) = route(exposed), let upstream = upstreams[server] else {
            let shown = MCPDisplayedText.field(exposed)
            return [.toClient(Self.error(id: client, code: -32602, message: "Unknown tool: \(shown)"))]
        }
        let rawArguments = params?["arguments"] ?? .object([:])
        // Exactness matters only where argument rules read the numbers. A call
        // no rule inspects forwards its original spellings (0.7, 19.99, …).
        let arguments: JSONValue
        if configuration.hasArgumentRules(server: upstream.definition, tool: tool) {
            guard let exact = rawArguments.withExactNumbers() else {
                let reason = "rv will not forward a number it cannot read exactly"
                return [
                    .audit(MCPCallRecord(server: server, tool: tool, decision: .deny, argumentKeys: [], isError: true, reason: reason)),
                    .toClient(Self.toolError(id: client, "\(reason). Do not retry; ask the user if you need it.")),
                ]
            }
            arguments = exact
        } else {
            arguments = rawArguments
        }
        let keys = arguments.objectValue?.keys.sorted() ?? []
        let decision = configuration.decision(server: upstream.definition, tool: tool, arguments: arguments)
        if decision == .deny {
            let reason = "rv policy denies \(server) tool \(tool)"
            let shown = "rv policy denies \(MCPDisplayedText.field(server)) tool \(MCPDisplayedText.field(tool))"
            return [
                .audit(MCPCallRecord(server: server, tool: tool, decision: .deny, argumentKeys: keys, isError: true, reason: reason)),
                .toClient(Self.toolError(id: client, "\(shown). Do not retry; ask the user if you need it.")),
            ]
        }
        guard phases[server] == .ready else {
            return unavailable(client: client, server: server, tool: tool, decision: decision, keys: keys)
        }
        // Forward only what approval covers: the tool name and the exact
        // arguments that were hashed and shown, plus the client's progress
        // token. Any other top-level params field would reach the upstream
        // unshown and unhashed, including on a granted retry.
        var forwarded = JSONObject()
        forwarded["name"] = .string(tool)
        forwarded["arguments"] = arguments
        if let token = params?["_meta"]?["progressToken"] {
            forwarded["_meta"] = .object(["progressToken": token])
        }
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
                let shownID = MCPDisplayedText.field(id)
                let shownServer = MCPDisplayedText.field(server)
                let shownTool = MCPDisplayedText.field(tool)
                outputs.append(.log(
                    "rejected approval \(shownID) for \(shownServer) tool \(shownTool): its grant was not signed by rv"))
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
            guard arguments.canonicalText.count <= Self.maximumElicitationArguments else {
                return argumentsNotShown(client: client, server: server, tool: tool, keys: keys)
            }
            let message = Self.elicitationMessage(server: server, tool: tool, arguments: arguments)
            guard Self.elicitationCovers(arguments, shown: message) else {
                return argumentsNotShown(client: client, server: server, tool: tool, keys: keys)
            }
            let key = "rv-approval-\(nextID)"
            nextID += 1
            held[key] = HeldCall(
                client: client, server: server, tool: tool, params: params, arguments: arguments, keys: keys,
                shown: message, heldAt: clock())
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
        let shownServer = MCPDisplayedText.field(server)
        let shownTool = MCPDisplayedText.field(tool)
        let shownID = MCPDisplayedText.field(ticket.id)
        let text = "rv paused this call: \(shownServer) tool \(shownTool) needs the user's approval. "
            + "Ask the user to run `rv mcp approve \(shownID)` in their own terminal "
            + "(or `rv mcp approve \(shownID) --always`), then call the tool again with the same arguments."
        var outputs: [MCPGatewayOutput] = [
            .audit(MCPCallRecord(
                server: server, tool: tool, decision: .ask, approvalID: ticket.id, argumentKeys: keys, isError: true,
                reason: "awaiting approval")),
            .toClient(Self.toolError(id: client, text)),
        ]
        if let code = ticket.code {
            let shownCode = MCPDisplayedText.field(code)
            outputs.append(.log(
                "approval \(shownID) for \(shownServer) tool \(shownTool): confirmation code \(shownCode)"))
        }
        return outputs
    }

    static func elicitationMessage(server: String, tool: String, arguments: JSONValue) -> String {
        let shownServer = MCPDisplayedText.field(server)
        let shownTool = MCPDisplayedText.field(tool)
        let shownArguments = MCPDisplayedText.field(arguments.canonicalText)
        return "rv: allow MCP server \(shownServer) to run tool \(shownTool)?\nArguments: \(shownArguments)"
    }

    /// True only when `shown` carries the arguments that would run, in full.
    /// A prefix, with or without an ellipsis, is not enough. The comparison
    /// is the escaped text the person is shown.
    static func elicitationCovers(_ arguments: JSONValue, shown: String) -> Bool {
        let marker = "\nArguments: "
        guard let range = shown.range(of: marker) else { return false }
        return shown[range.upperBound...] == MCPDisplayedText.field(arguments.canonicalText)
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
                "rv refused \(MCPDisplayedText.field(server)) tool \(MCPDisplayedText.field(tool)): the approval prompt did not include the full arguments. The call was not run.")),
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
                return [.toClient(displayedProgress(scrub(message, for: server)))]
            default:
                return []
            }
        }
        guard let id = message["id"]?.intValue, let entry = pending[id] else { return [] }
        // A pending request belongs to one upstream. A reply from another does
        // not consume it: request IDs are sequential, so any upstream could
        // otherwise race a forged result for a peer's tool call.
        if let owner = entry.owner, owner != server {
            return [.log("MCP server \(server) answered request \(id) owned by \(owner); ignoring")]
        }
        pending.removeValue(forKey: id)
        switch entry {
        case .initialize:
            if message["result"]?.objectValue != nil {
                phases[server] = .ready
                return [.toUpstream(server: server, message: Self.notification("notifications/initialized", nil))]
                    + releaseWaiting()
            }
            let raw = message["error"]?["message"]?.stringValue ?? "initialize failed"
            let reason = MCPDisplayedText.field(scrubText(raw, for: server))
            phases[server] = .failed(reason)
            return [.log("MCP server \(MCPDisplayedText.field(server)) failed to initialize: \(reason)")] + releaseWaiting()
        case .list(let fanout, _):
            return listPage(fanout: fanout, server: server, message: message)
        case .call(let client, _, let tool, let keys, let approval, let started):
            let isError = message["error"] != nil || message["result"]?["isError"]?.boolValue == true
            var reply = clientVisibleReply(message, server: server).objectValue ?? JSONObject()
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
            state.pages[server, default: 0] += 1
            if state.tools.count > Self.maximumListedTools {
                state.tools = Array(state.tools.prefix(Self.maximumListedTools))
                outputs.append(.log("MCP tool listing exceeded \(Self.maximumListedTools) tools; truncating"))
            } else if let cursor = message["result"]?["nextCursor"]?.stringValue, cursor.isEmpty == false {
                let key = server + "\0" + cursor
                if state.seenCursors.contains(key) || state.pages[server, default: 0] >= Self.maximumListPagesPerServer {
                    outputs.append(.log("MCP server \(server) cycled or over-paged its tool list; stopping pagination"))
                } else {
                    state.seenCursors.insert(key)
                    fanouts[fanout] = state
                    let id = allocate(.list(fanout: fanout, server: server))
                    return outputs + [.toUpstream(server: server, message: Self.request(
                        id: .int(id), method: "tools/list", params: .object(["cursor": .string(cursor)])))]
                }
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
        if let search = state.search {
            return outputs + [
                .audit(MCPCallRecord(
                    server: "rv", tool: Self.searchToolName, decision: .allow, argumentKeys: ["query", "limit"],
                    isError: false, reason: "searched \(state.tools.count) tools")),
                .toClient(Self.searchResult(id: state.client, tools: state.tools, search: search)),
            ]
        }
        return outputs + [.toClient(Self.result(id: state.client, .object(["tools": .array(state.tools)])))]
    }

    /// Tools whose name or description holds every term; name matches first.
    static func searchResult(id: JSONValue, tools: [JSONValue], search: Search) -> JSONValue {
        func holdsAll(_ text: String) -> Bool {
            let lowered = text.lowercased()
            return search.terms.allSatisfy { lowered.contains($0) }
        }
        let matches = tools.filter {
            holdsAll(($0["name"]?.stringValue ?? "") + " " + ($0["description"]?.stringValue ?? ""))
        }
        let byName = matches.filter { holdsAll($0["name"]?.stringValue ?? "") }
        let rest = matches.filter { holdsAll($0["name"]?.stringValue ?? "") == false }
        let found = JSONValue.object([
            "tools": .array(Array((byName + rest).prefix(search.limit))),
            "total": .int(matches.count),
        ])
        return result(id: id, .object([
            "content": .array([.object(["type": .string("text"), "text": .string(found.compactText)])]),
            "structuredContent": found,
        ]))
    }

    static let metaTools: [JSONValue] = [
        .object([
            "name": .string(searchToolName),
            "description": .string(
                "Search the tools rv serves by words in their names and descriptions. Returns each match with its "
                    + "input schema; call one with rv_call_tool."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Words every match must contain; empty lists every tool"),
                    ]),
                    "limit": .object([
                        "type": .string("integer"), "minimum": .int(1), "maximum": .int(searchLimits.maximum),
                        "default": .int(searchLimits.default),
                    ]),
                ]),
            ]),
        ]),
        .object([
            "name": .string(callToolName),
            "description": .string(
                "Call a tool found with rv_search_tools. rv applies the same policy and approvals as a direct call."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Tool name from rv_search_tools")]),
                    "arguments": .object(["type": .string("object"), "description": .string("The tool's arguments")]),
                ]),
                "required": .array([.string("name")]),
            ]),
        ]),
    ]

    /// Denied tools are hidden; `ask` tools say so in their description, and
    /// so do tools whose arguments can change the decision.
    /// Routing uses the raw name. Every other string the client can read,
    /// including title and schemas, is escaped once.
    func exposedTool(_ tool: JSONValue, upstream: Upstream) -> JSONValue? {
        let scrubbed = scrub(tool, for: upstream.definition.name)
        guard let object = scrubbed.objectValue, let name = object["name"]?.stringValue else {
            return nil
        }
        let rawDescription = object["description"]?.stringValue
        switch configuration.decision(server: upstream.definition, tool: name) {
        case .deny:
            return nil
        case .ask, .allow:
            break
        }
        var listedName = name
        if prefixesTools {
            let exposedName = upstream.definition.name + Self.separator + name
            // A shorter server's tool must not be listed under a name the
            // longest matching server owns; that call would not reach it.
            guard route(exposedName)?.server == upstream.definition.name else { return nil }
            listedName = exposedName
        }
        guard var walked = displayedContent(.object(object)).objectValue else { return nil }
        if configuration.decision(server: upstream.definition, tool: name) == .ask {
            walked["description"] = .string("[rv: needs the user's approval] " + MCPDisplayedText.field(rawDescription ?? ""))
        } else if configuration.hasArgumentRules(server: upstream.definition, tool: name) {
            walked["description"] = .string(
                "[rv: some arguments need the user's approval or are refused] " + MCPDisplayedText.field(rawDescription ?? ""))
        }
        walked["name"] = .string(MCPDisplayedText.field(listedName))
        return .object(walked)
    }

    /// Every string in a progress notification, including the token.
    func displayedProgress(_ message: JSONValue) -> JSONValue {
        displayedContent(message)
    }

    /// Every string in a scrubbed tool result, including a successful call,
    /// nested resource text, and error data.
    func clientVisibleReply(_ message: JSONValue, server: String) -> JSONValue {
        displayedContent(scrub(message, for: server))
    }

    /// Escape every string the client would display. Object keys are escaped
    /// too. Each raw string is escaped once.
    func displayedContent(_ content: JSONValue) -> JSONValue {
        switch content {
        case .string(let text):
            return .string(MCPDisplayedText.field(text))
        case .array(let items):
            return .array(items.map(displayedContent))
        case .object(let object):
            var copy = JSONObject()
            for (key, value) in object.entries {
                copy[MCPDisplayedText.field(key)] = displayedContent(value)
            }
            return .object(copy)
        default:
            return content
        }
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
        for (key, call) in held.filter({ $0.value.server == server }).sorted(by: { $0.key < $1.key }) {
            held[key] = nil
            outputs.append(.audit(MCPCallRecord(
                server: server, tool: call.tool, decision: .ask, approvalID: key, argumentKeys: call.keys,
                isError: true, reason: "upstream exited")))
            outputs.append(.toClient(Self.notification("notifications/cancelled", .object([
                "requestId": .string(key), "reason": .string("the MCP server exited"),
            ]))))
            outputs.append(.toClient(Self.error(id: call.client, code: -32603, message: "MCP server \(server) exited")))
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
            for (key, item) in object.entries {
                scrubbed[scrubText(key, secrets: secrets)] = scrub(item, secrets: secrets)
            }
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
