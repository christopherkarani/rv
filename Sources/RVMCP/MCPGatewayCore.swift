import Foundation
import RVHistory

public enum MCPGatewayInput: Sendable, Equatable {
    case client(JSONValue)
    /// A line from the client that is not JSON.
    case clientUnparseable
    case upstream(server: String, message: JSONValue)
    case upstreamExited(server: String)
    /// Time passed: deadlines are checked, as they are on every input. The
    /// runtime sends one about every second.
    case tick
}

public enum MCPGatewayOutput: Sendable, Equatable {
    case toClient(JSONValue)
    case toUpstream(server: String, message: JSONValue)
    case audit(MCPCallRecord)
    /// Any other audit event (for example a rejected forged grant).
    case event(AuditEvent)
    case log(String)
    /// Stop this upstream now: kill its process, or close its connection.
    /// The core already counts it failed; its exit may still be reported.
    case stopUpstream(server: String)
}

/// How long the gateway waits for an upstream's `initialize` and for each
/// `tools/list` page. A `tools/call` waits its server's `callTimeoutSeconds`.
public struct MCPGatewayDeadlines: Sendable, Equatable {
    public static let standardStart: TimeInterval = 30
    public static let standardList: TimeInterval = 30

    public var start: TimeInterval
    public var list: TimeInterval

    public init(start: TimeInterval = standardStart, list: TimeInterval = standardList) {
        self.start = start
        self.list = list
    }
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
    /// An approval that let an `ask` call go to the upstream.
    public struct Grant: Sendable, Equatable {
        public var approvalID: String
        public var channel: MCPApprovalChannel

        public init(approvalID: String, channel: MCPApprovalChannel) {
            self.approvalID = approvalID
            self.channel = channel
        }
    }

    /// How the call ended. A refused call cannot carry a duration, and no
    /// outcome is inferred from a missing one.
    public enum Outcome: Sendable, Equatable {
        /// The upstream answered, with a result or an error.
        case ran(durationMilliseconds: Int, grant: Grant?)
        /// Allowed (or granted), then the upstream or rv failed before an answer.
        case interrupted(grant: Grant?)
        /// Allowed (or granted) and about to go upstream. Written before the
        /// call is forwarded; a call whose record cannot be written is refused.
        case forwarding(grant: Grant?)
        /// Stopped for an approval nobody has answered yet.
        case awaiting(approvalID: String?)
        /// The prompt ended without a yes: the user refused, the prompt failed
        /// or timed out, or its upstream exited while it was shown.
        case declined(approvalID: String)
        /// Nothing went upstream: rv refused before any grant, or answered itself (search).
        case notRun
    }

    public var server: String
    public var tool: String
    public var decision: MCPToolDecision
    public var argumentKeys: [String]
    public var isError: Bool
    public var reason: String?
    public var outcome: Outcome

    public init(
        server: String, tool: String, decision: MCPToolDecision, argumentKeys: [String], isError: Bool,
        reason: String? = nil, outcome: Outcome
    ) {
        self.server = server
        self.tool = tool
        self.decision = decision
        self.argumentKeys = argumentKeys
        self.isError = isError
        self.reason = reason
        self.outcome = outcome
    }

    public var approvalID: String? {
        switch outcome {
        case .ran(_, let grant), .interrupted(let grant), .forwarding(let grant): grant?.approvalID
        case .awaiting(let id): id
        case .declined(let id): id
        case .notRun: nil
        }
    }

    public var approvedVia: MCPApprovalChannel? {
        switch outcome {
        case .ran(_, let grant), .interrupted(let grant), .forwarding(let grant): grant?.channel
        case .awaiting, .declined, .notRun: nil
        }
    }

    public var durationMilliseconds: Int? {
        if case .ran(let duration, _) = outcome { duration } else { nil }
    }

    /// The approval prompt for an `ask` call ended without a yes.
    public var declined: Bool {
        if case .declined = outcome { true } else { false }
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
        var grant: MCPCallRecord.Grant { MCPCallRecord.Grant(approvalID: id, channel: channel) }
    }

    /// A `tools/call` the upstream has not answered.
    struct Call {
        var client: JSONValue
        var server: String
        var tool: String
        var keys: [String]
        var approval: Approval?
        var started: Date
        /// Past this the client is told the call timed out. Valid progress
        /// for the call moves it, never past `ceiling`.
        var deadline: Date
        /// The total limit: `callTimeoutCeilingFactor` times the server's
        /// call timeout after `started`, however much progress arrives.
        var ceiling: Date
    }

    /// Every request rv sends upstream, until it is answered or expires.
    enum Pending {
        case initialize(server: String, deadline: Date)
        case list(fanout: Int, server: String, deadline: Date)
        case call(Call)
        /// Cancelled by the client, or timed out: a late answer is dropped.
        /// Forgotten at `until`, or when its server exits.
        case cancelled(server: String, until: Date)

        /// The upstream that owns this request; nil once cancelled. A reply
        /// from any other upstream must not consume the entry.
        var owner: String? {
            switch self {
            case .initialize(let server, _), .list(_, let server, _): server
            case .call(let call): call.server
            case .cancelled: nil
            }
        }

        var deadline: Date {
            switch self {
            case .initialize(_, let deadline), .list(_, _, let deadline): deadline
            case .call(let call): call.deadline
            case .cancelled(_, let until): until
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
        /// Each server's listed tools, held until its listing ends so they
        /// are checked against its pins as one listing.
        var listed: [String: [JSONValue]] = [:]
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
        /// The definition the prompt was shown for. Accept runs only while
        /// the tool is still listed with it.
        var binding: MCPToolBinding
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
    /// `mcp.tool.changed` events per server per session; past this one
    /// event says the rest are suppressed. Those tools still ask and are
    /// still queued for `rv mcp trust`, within the queue's budget.
    static let maximumChangeEvents = 64
    /// Tools per server whose definitions a session tracks against the
    /// pins, across all of its listings. A tool past this is never pinned:
    /// it asks, or, once its server listed a hiding tool past this
    /// (`hidingUntracked`), is hidden and refused. One listing already
    /// lists at most this many.
    static let maximumTrackedTools = maximumListedTools
    /// Definitions per server a session offers to the review queue. Past
    /// this a new definition is not queued (its tool still asks).
    static let maximumTrackedChanges = 1024
    /// Longest progress `message` passed to the client, in UTF-8 bytes.
    static let maximumProgressMessageBytes = 512
    /// Longest spelling of a forwarded progress `progress` or `total`.
    static let maximumProgressNumberBytes = 32
    /// Most bytes of an upstream's `initialize` error text that reach stderr.
    static let maximumInitializeErrorBytes = 512

    /// Upstream tool names rv lists and routes. Any other name (prose,
    /// controls, separators, over 64 bytes) is neither listed nor called.
    static func servesToolName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...64).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }

    let configuration: MCPConfiguration
    var upstreams: [String: Upstream]
    let order: [String]
    let approvals: MCPApprovalGate
    let pinning: MCPToolPinning
    /// Writes the `mcp.call` record for a call about to go upstream; false
    /// when it could not be written, and the call is then refused.
    let recordForward: @Sendable (MCPCallRecord) -> Bool
    let clock: () -> Date
    let deadlines: MCPGatewayDeadlines
    let version: String

    /// server → tool → definition hash the user trusted; nil when the pin
    /// store could not be read or verified. The gateway never adds pins.
    let pins: [String: [String: String]]?
    /// server → tool → hash of the definition this session last listed. At
    /// most `maximumTrackedTools` tools per server; a tool past that is
    /// never observed, so it is unverified and asks, or is refused once its
    /// server is in `hidingUntracked`.
    var observed: [String: [String: String]] = [:]
    /// `server\0tool` listed this session with a definition that differs
    /// from its pin or from another listing. Sticky: such a tool is never
    /// pinned again this session, whatever it lists next. Only observed
    /// tools are tainted, so this is bounded with `observed`.
    var tainted: Set<String> = []
    /// server → `tool\0hash` offered to the review queue and not dropped by
    /// it; at most `maximumTrackedChanges` per server.
    var reportedChanges: [String: Set<String>] = [:]
    /// server → `tool\0hash` already audited as not pinned; bounded by
    /// `maximumChangeEvents` per server.
    var eventedChanges: [String: Set<String>] = [:]
    /// Servers already told on stderr that the review queue did not keep
    /// some of their tools.
    var queueNoticed: Set<String> = []
    /// Servers already told on stderr that they list more tools than rv tracks.
    var untrackedNoticed: Set<String> = []
    /// Servers already told (stderr and one event) that they reached
    /// `maximumTrackedChanges`, so later changed definitions are not queued.
    var trackingFullNoticed: Set<String> = []
    /// Servers already reported on stderr as having untrusted tools.
    var untrustedNoticed: Set<String> = []
    /// Servers already reported on stderr as listing names rv does not serve.
    var unservedNoticed: Set<String> = []
    /// server → tools a listing this session named with a schema
    /// `schemaNamesHideText` rejects, until a later listing shows them with
    /// one it does not; neither listed nor called. With pinning enforced,
    /// only tools in `observed`, so bounded with it.
    var hidingSchemas: [String: Set<String>] = [:]
    /// Servers that listed such a tool past `maximumTrackedTools`: every
    /// tool of theirs not in `observed` is refused like one in `hidingSchemas`.
    var hidingUntracked: Set<String> = []
    /// Servers already reported on stderr as listing such tools.
    var hidingSchemaNoticed: Set<String> = []
    /// server → `mcp.tool.changed` events written this session.
    var changeEvents: [String: Int] = [:]
    /// pending call id → the `progressToken` the client sent with it.
    var progressTokens: [Int: JSONValue] = [:]
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
        pinning: MCPToolPinning,
        recordForward: @escaping @Sendable (MCPCallRecord) -> Bool,
        version: String = "1",
        clock: @escaping () -> Date = { Date() },
        deadlines: MCPGatewayDeadlines = MCPGatewayDeadlines()
    ) {
        self.configuration = configuration
        self.upstreams = Dictionary(upstreams.map { ($0.definition.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.order = upstreams.map(\.definition.name)
        self.approvals = approvals
        self.pinning = pinning
        self.pins = pinning.pins
        self.recordForward = recordForward
        self.clock = clock
        self.deadlines = deadlines
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
            let id = allocate(.initialize(server: server, deadline: clock().addingTimeInterval(deadlines.start)))
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
            return clientMessage(message) + expireHeld() + expireDeadlines()
        }
        var outputs = expireHeld() + expireDeadlines()
        switch input {
        case .client(let message): outputs += clientMessage(message)
        case .clientUnparseable: outputs.append(.toClient(Self.error(id: .null, code: -32700, message: "Parse error")))
        case .upstream(let server, let message): outputs += upstreamMessage(server, message)
        case .upstreamExited(let server): outputs += upstreamExited(server)
        case .tick: break
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
                server: call.server, tool: call.tool, decision: .ask, argumentKeys: call.keys,
                isError: true, reason: "approval prompt was not answered in time", outcome: .declined(approvalID: key))))
            outputs.append(.toClient(Self.notification("notifications/cancelled", .object([
                "requestId": .string(key), "reason": .string("the approval prompt was not answered in time"),
            ]))))
            outputs.append(.toClient(Self.toolError(
                id: call.client,
                "rv's approval prompt for \(MCPDisplayedText.field(call.server)) tool \(MCPDisplayedText.field(call.tool)) was not answered in time; the call was not run.")))
        }
        return outputs
    }

    /// A call may run at most this many times its server's call timeout in
    /// all, so an upstream that keeps sending progress cannot hold it open
    /// forever.
    static let callTimeoutCeilingFactor: TimeInterval = 10

    /// How long a `tools/call` to `server` may go unanswered.
    func callTimeout(_ server: String) -> TimeInterval {
        TimeInterval(upstreams[server]?.definition.callTimeoutSeconds ?? MCPServerDefinition.defaultCallTimeoutSeconds)
    }

    static func seconds(_ interval: TimeInterval) -> String {
        interval == interval.rounded() ? String(Int(interval)) : String(interval)
    }

    /// Ends every request whose deadline passed, oldest first: an
    /// `initialize` fails its server, a `tools/list` page ends that server's
    /// part of the listing, a `tools/call` fails the client's request (it is
    /// cancelled upstream, never sent again), and a cancelled entry is
    /// forgotten.
    mutating func expireDeadlines() -> [MCPGatewayOutput] {
        let now = clock()
        var outputs: [MCPGatewayOutput] = []
        for (id, entry) in pending.filter({ $0.value.deadline <= now }).sorted(by: { $0.key < $1.key }) {
            switch entry {
            case .initialize(let server, _):
                pending[id] = nil
                let limit = Self.seconds(deadlines.start)
                phases[server] = .failed("it did not answer initialize within \(limit) s")
                outputs.append(.log(
                    "MCP server \(MCPDisplayedText.field(server)) did not answer initialize within \(limit) s; stopping it"))
                outputs.append(.stopUpstream(server: server))
                outputs += releaseWaiting()
            case .list(let fanout, let server, _):
                pending[id] = nil
                outputs += listPage(
                    fanout: fanout, server: server, message: .null,
                    failure: "did not list tools within \(Self.seconds(deadlines.list)) s")
            case .call(let call):
                outputs += callTimedOut(id, call, now: now)
            case .cancelled:
                pending[id] = nil
            }
        }
        return outputs
    }

    /// The client is told, the upstream is asked to stop, and the record
    /// says the call was interrupted. A late answer is then dropped.
    mutating func callTimedOut(_ id: Int, _ call: Call, now: Date) -> [MCPGatewayOutput] {
        let limit = callTimeout(call.server)
        pending[id] = .cancelled(server: call.server, until: now.addingTimeInterval(limit))
        progressTokens[id] = nil
        let shownServer = MCPDisplayedText.field(call.server)
        let shownTool = MCPDisplayedText.field(call.tool)
        let reason: String, waited: String, answer: String
        if call.deadline >= call.ceiling {
            let total = Self.seconds(call.started.distance(to: call.ceiling))
            reason = "timed out: total limit of \(total) s reached"
            waited = total
            answer = "did not finish tool \(shownTool) within its total limit of \(total) s"
        } else {
            let seconds = Self.seconds(limit)
            reason = "timed out: no answer within \(seconds) s"
            waited = seconds
            answer = "did not answer tool \(shownTool) within \(seconds) s"
        }
        return [
            .audit(MCPCallRecord(
                server: call.server, tool: call.tool, decision: call.approval == nil ? .allow : .ask,
                argumentKeys: call.keys, isError: true, reason: reason,
                outcome: .interrupted(grant: call.approval?.grant))),
            .toUpstream(server: call.server, message: Self.notification("notifications/cancelled", .object([
                "requestId": .int(id), "reason": .string("rv stopped waiting after \(waited) s"),
            ]))),
            .toClient(Self.error(
                id: call.client, code: -32603,
                message: "MCP server \(shownServer) \(answer); "
                    + "rv stopped waiting. The call may still have run, so check before calling it again.")),
        ]
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
                        server: call.server, tool: call.tool, decision: .ask, argumentKeys: call.keys,
                        isError: true, reason: reason, outcome: .declined(approvalID: key))),
                    .toClient(Self.toolError(
                        id: call.client,
                        "rv could not get an answer to its approval prompt for \(MCPDisplayedText.field(call.server)) tool \(MCPDisplayedText.field(call.tool)); the call was not run. Do not retry unless the user asks.")),
                ]
            }
            return outOfBand(
                client: call.client, server: call.server, tool: call.tool, arguments: call.arguments, keys: call.keys,
                binding: call.binding)
        }
        let accepted = Self.elicitationAccepts(message["result"])
        guard accepted else {
            let reason = "declined by the user"
            let shownServer = MCPDisplayedText.field(call.server)
            let shownTool = MCPDisplayedText.field(call.tool)
            return [
                .audit(MCPCallRecord(
                    server: call.server, tool: call.tool, decision: .ask, argumentKeys: call.keys,
                    isError: true, reason: reason, outcome: .declined(approvalID: key))),
                .toClient(Self.toolError(
                    id: call.client,
                    "The user declined \(shownServer) tool \(shownTool) in rv's approval prompt. Do not retry unless the user asks.")),
            ]
        }
        guard phases[call.server] == .ready else {
            return unavailable(
                client: call.client, server: call.server, tool: call.tool, decision: .ask, keys: call.keys, approved: true)
        }
        guard Self.elicitationCovers(call.arguments, shown: call.shown) else {
            return argumentsNotShown(client: call.client, server: call.server, tool: call.tool, keys: call.keys)
        }
        guard toolBinding(server: call.server, tool: call.tool) == call.binding else {
            let reason = "the tool definition changed while the approval prompt was shown"
            return [
                .audit(MCPCallRecord(
                    server: call.server, tool: call.tool, decision: .ask, argumentKeys: call.keys, isError: true,
                    reason: reason, outcome: .declined(approvalID: key))),
                .toClient(Self.toolError(
                    id: call.client,
                    "rv refused \(MCPDisplayedText.field(call.server)) tool \(MCPDisplayedText.field(call.tool)): \(reason). The call was not run.")),
            ]
        }
        // Refused as `callTool` would now: the prompt may predate a listing
        // that left an untracked tool's binding unchanged. The record closes
        // the prompt's `ask` row, as a changed binding's does.
        if let reason = hiddenRefusal(server: call.server, tool: call.tool) {
            let exposed = prefixesTools ? call.server + Self.separator + call.tool : call.tool
            return [
                .audit(MCPCallRecord(
                    server: call.server, tool: call.tool, decision: .ask, argumentKeys: call.keys, isError: true,
                    reason: reason, outcome: .declined(approvalID: key))),
                .toClient(Self.error(id: call.client, code: -32602, message: "Unknown tool: \(MCPDisplayedText.field(exposed))")),
            ]
        }
        return forward(
            client: call.client, server: call.server, tool: call.tool, keys: call.keys,
            approval: Approval(id: key, channel: .elicitation), params: call.params)
    }

    /// Records the call, then forwards it. A call whose record cannot be
    /// written is refused: nothing reaches an upstream unaudited.
    mutating func forward(
        client: JSONValue, server: String, tool: String, keys: [String], approval: Approval?, params: JSONObject
    ) -> [MCPGatewayOutput] {
        let record = MCPCallRecord(
            server: server, tool: tool, decision: approval == nil ? .allow : .ask, argumentKeys: keys, isError: false,
            outcome: .forwarding(grant: approval?.grant))
        guard recordForward(record) else {
            let shownServer = MCPDisplayedText.field(server)
            let shownTool = MCPDisplayedText.field(tool)
            return [
                .log("could not write the audit record for \(shownServer) tool \(shownTool); the call was not forwarded"),
                .toClient(Self.error(
                    id: client, code: -32603,
                    message: "rv could not write the audit record for \(shownServer) tool \(shownTool); the call was not run")),
            ]
        }
        let started = clock()
        let timeout = callTimeout(server)
        let id = allocate(.call(Call(
            client: client, server: server, tool: tool, keys: keys, approval: approval, started: started,
            deadline: started.addingTimeInterval(timeout),
            ceiling: started.addingTimeInterval(timeout * Self.callTimeoutCeilingFactor))))
        if let token = params["_meta"]?["progressToken"] { progressTokens[id] = token }
        return [.toUpstream(server: server, message: Self.request(id: .int(id), method: "tools/call", params: .object(params)))]
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
            guard case .call(let call) = entry, call.client == target else { continue }
            let server = call.server
            pending[id] = .cancelled(server: server, until: clock().addingTimeInterval(callTimeout(server)))
            progressTokens[id] = nil
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
        let deadline = clock().addingTimeInterval(deadlines.list)
        return ready.map { server in
            let id = allocate(.list(fanout: fanout, server: server, deadline: deadline))
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
                    .audit(MCPCallRecord(server: server, tool: tool, decision: .deny, argumentKeys: [], isError: true, reason: reason, outcome: .notRun)),
                    .toClient(Self.toolError(id: client, "\(reason). Do not retry; ask the user if you need it.")),
                ]
            }
            arguments = exact
        } else {
            arguments = rawArguments
        }
        let keys = arguments.objectValue?.keys.sorted() ?? []
        var decision = configuration.decision(server: upstream.definition, tool: tool, arguments: arguments)
        // A tool not listed this session only exactly as the user trusted
        // it (changed, new, or unverifiable) is never called under `allow`.
        let binding = toolBinding(server: server, tool: tool)
        if decision == .allow, binding.pinStatus != .pinned { decision = .ask }
        if decision == .deny {
            let reason = "rv policy denies \(server) tool \(tool)"
            let shown = "rv policy denies \(MCPDisplayedText.field(server)) tool \(MCPDisplayedText.field(tool))"
            return [
                .audit(MCPCallRecord(server: server, tool: tool, decision: .deny, argumentKeys: keys, isError: true, reason: reason, outcome: .notRun)),
                .toClient(Self.toolError(id: client, "\(shown). Do not retry; ask the user if you need it.")),
            ]
        }
        // rv never lists such a name, so no call to it is meant for a tool
        // rv serves; refusing it also keeps routing on the raw name.
        guard Self.servesToolName(tool) else {
            return [
                .audit(MCPCallRecord(
                    server: server, tool: tool, decision: .deny, argumentKeys: keys, isError: true,
                    reason: "rv does not serve tools with this name", outcome: .notRun)),
                .toClient(Self.error(id: client, code: -32602, message: "Unknown tool: \(MCPDisplayedText.field(exposed))")),
            ]
        }
        // Not listed either: its schema names a property a client may show
        // raw, or it may and rv could not track it.
        if let reason = hiddenRefusal(server: server, tool: tool) {
            return [
                .audit(MCPCallRecord(
                    server: server, tool: tool, decision: .deny, argumentKeys: keys, isError: true,
                    reason: reason, outcome: .notRun)),
                .toClient(Self.error(id: client, code: -32602, message: "Unknown tool: \(MCPDisplayedText.field(exposed))")),
            ]
        }
        guard phases[server] == .ready else {
            return unavailable(client: client, server: server, tool: tool, decision: decision, keys: keys, approved: false)
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
            switch approvals.consumeGrant(server, tool, hash, keys, binding) {
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
                return outputs + askUser(
                    client: client, server: server, tool: tool, params: forwarded, arguments: arguments, keys: keys,
                    binding: binding)
            }
        }
        return outputs + forward(client: client, server: server, tool: tool, keys: keys, approval: approval, params: forwarded)
    }

    /// Elicitation when the client can show it; otherwise a pending request
    /// the user approves out of band with `rv mcp approve`.
    mutating func askUser(
        client: JSONValue, server: String, tool: String, params: JSONObject, arguments: JSONValue, keys: [String],
        binding: MCPToolBinding
    ) -> [MCPGatewayOutput] {
        if clientElicits, held.count < Self.maximumHeld {
            guard arguments.canonicalText.count <= Self.maximumElicitationArguments else {
                return argumentsNotShown(client: client, server: server, tool: tool, keys: keys)
            }
            let message = Self.elicitationMessage(
                server: server, tool: tool, arguments: arguments, note: Self.pinNote(binding.pinStatus))
            guard Self.elicitationCovers(arguments, shown: message) else {
                return argumentsNotShown(client: client, server: server, tool: tool, keys: keys)
            }
            let key = "rv-approval-\(nextID)"
            nextID += 1
            held[key] = HeldCall(
                client: client, server: server, tool: tool, params: params, arguments: arguments, keys: keys,
                binding: binding, shown: message, heldAt: clock())
            return [
                .audit(MCPCallRecord(
                    server: server, tool: tool, decision: .ask, argumentKeys: keys, isError: false,
                    reason: "awaiting approval in the client", outcome: .awaiting(approvalID: key))),
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
        return outOfBand(client: client, server: server, tool: tool, arguments: arguments, keys: keys, binding: binding)
    }

    func outOfBand(
        client: JSONValue, server: String, tool: String, arguments: JSONValue, keys: [String], binding: MCPToolBinding
    ) -> [MCPGatewayOutput] {
        let note = Self.pinNote(binding.pinStatus)
        guard let ticket = approvals.request(server, tool, arguments.canonicalHash, keys, binding) else {
            let reason = "rv could not record an approval request"
            return [
                .audit(MCPCallRecord(server: server, tool: tool, decision: .ask, argumentKeys: keys, isError: true, reason: reason, outcome: .notRun)),
                .toClient(Self.toolError(id: client, reason)),
            ]
        }
        let shownServer = MCPDisplayedText.field(server)
        let shownTool = MCPDisplayedText.field(tool)
        let shownID = MCPDisplayedText.field(ticket.id)
        let text = "rv paused this call: \(shownServer) tool \(shownTool) needs the user's approval. "
            + (note.map { $0 + " " } ?? "")
            + "Ask the user to run `rv mcp approve \(shownID)` in their own terminal "
            + "(or `rv mcp approve \(shownID) --always`), then call the tool again with the same arguments."
        var outputs: [MCPGatewayOutput] = [
            .audit(MCPCallRecord(
                server: server, tool: tool, decision: .ask, argumentKeys: keys, isError: true,
                reason: "awaiting approval", outcome: .awaiting(approvalID: ticket.id))),
            .toClient(Self.toolError(id: client, text)),
        ]
        if let code = ticket.code {
            let shownCode = MCPDisplayedText.field(code)
            outputs.append(.log(
                "approval \(shownID) for \(shownServer) tool \(shownTool): confirmation code \(shownCode)"))
        }
        return outputs
    }

    static func elicitationMessage(server: String, tool: String, arguments: JSONValue, note: String? = nil) -> String {
        let shownServer = MCPDisplayedText.field(server)
        let shownTool = MCPDisplayedText.field(tool)
        let shownArguments = MCPDisplayedText.field(arguments.canonicalText)
        let warning = note.map { "\n" + $0 } ?? ""
        return "rv: allow MCP server \(shownServer) to run tool \(shownTool)?\(warning)\nArguments: \(shownArguments)"
    }

    /// Why a tool the policy allows still asks, or nil when it is pinned.
    /// rv's own text: it never contains the `\nArguments: ` marker.
    static func pinNote(_ status: MCPToolPinStatus) -> String? {
        switch status {
        case .pinned: nil
        case .changed:
            "Its definition changed since the user trusted it; `rv mcp trust` reviews and pins it."
        case .new: "The user has not trusted its definition yet; `rv mcp trust` reviews and pins it."
        case .unverified: "rv could not check it against the tool definitions the user trusted."
        }
    }

    /// The whole listed description of a tool that is not pinned. Such a
    /// tool is listed with only its name, this marker and an empty object
    /// schema (`exposedTool`).
    static func pinMarker(_ status: MCPToolPinStatus) -> String? {
        let hidden = "its description and parameters are hidden until the user runs `rv mcp trust`; every call needs the user's approval]"
        return switch status {
        case .pinned: nil
        case .changed: "[rv: this tool changed since the user trusted it; " + hidden
        case .new: "[rv: this tool is not yet trusted by the user; " + hidden
        case .unverified: "[rv: rv could not check this tool against the tools the user trusted; " + hidden
        }
    }

    /// The tool against the pins. Pinned only when every listing this
    /// session matched its pin. A tool not listed this session cannot be
    /// checked, so it is unverified.
    func pinStatus(server: String, tool: String) -> MCPToolPinStatus {
        guard pinning.enforced else { return .pinned }
        guard let pins, let seen = observed[server]?[tool] else { return .unverified }
        guard let pinned = pins[server]?[tool] else { return .new }
        guard tainted.contains(server + "\0" + tool) == false, pinned == seen else { return .changed }
        return .pinned
    }

    /// What an approval for this tool is bound to right now.
    func toolBinding(server: String, tool: String) -> MCPToolBinding {
        MCPToolBinding(definitionHash: observed[server]?[tool] ?? "", pinStatus: pinStatus(server: server, tool: tool))
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
                server: server, tool: tool, decision: .ask, argumentKeys: keys, isError: true, reason: reason,
                outcome: .notRun)),
            .toClient(Self.toolError(
                id: client,
                "rv refused \(MCPDisplayedText.field(server)) tool \(MCPDisplayedText.field(tool)): the approval prompt did not include the full arguments. The call was not run.")),
        ]
    }

    func unavailable(
        client: JSONValue, server: String, tool: String, decision: MCPToolDecision, keys: [String],
        approved: Bool
    ) -> [MCPGatewayOutput] {
        let reason: String
        if case .failed(let why)? = phases[server] { reason = why } else { reason = "not ready" }
        return [
            .audit(MCPCallRecord(
                server: server, tool: tool, decision: decision == .ask ? .ask : .allow, argumentKeys: keys, isError: true,
                reason: "upstream unavailable: \(reason)", outcome: approved ? .interrupted(grant: nil) : .notRun)),
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
                return progress(from: server, message["params"]).map { [.toClient($0)] } ?? []
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
        progressTokens[id] = nil
        switch entry {
        case .initialize:
            if message["result"]?.objectValue != nil {
                phases[server] = .ready
                return [.toUpstream(server: server, message: Self.notification("notifications/initialized", nil))]
                    + releaseWaiting()
            }
            let raw = message["error"]?["message"]?.stringValue ?? "initialize failed"
            let reason = MCPCallRecord.bounded(
                MCPDisplayedText.field(scrubText(raw, for: server)), Self.maximumInitializeErrorBytes)
            // The upstream's text goes to stderr only: a server's error is
            // not a channel to the client or the model. It is stopped, as
            // one that never answers is.
            phases[server] = .failed("it failed to initialize")
            return [
                .log("MCP server \(MCPDisplayedText.field(server)) failed to initialize: \(reason)"),
                .stopUpstream(server: server),
            ] + releaseWaiting()
        case .list(let fanout, _, _):
            return listPage(fanout: fanout, server: server, message: message)
        case .call(let call):
            let client = call.client, tool = call.tool, keys = call.keys, approval = call.approval, started = call.started
            // The reply is rebuilt from the upstream's result or error;
            // no other field of its message reaches the client.
            let visible = clientVisibleReply(message, server: server)
            let reply: JSONValue
            if let result = visible["result"] {
                reply = Self.result(id: client, result)
            } else if let error = visible["error"] {
                reply = .object(["jsonrpc": .string("2.0"), "id": client, "error": error])
            } else {
                reply = Self.error(
                    id: client, code: -32603,
                    message: "MCP server \(MCPDisplayedText.field(server)) answered with neither a result nor an error")
            }
            let isError = message["result"] == nil || message["result"]?["isError"]?.boolValue == true
            let duration = Int((clock().timeIntervalSince(started) * 1000).rounded())
            return [
                .audit(MCPCallRecord(
                    server: server, tool: tool, decision: approval == nil ? .allow : .ask, argumentKeys: keys,
                    isError: isError,
                    outcome: .ran(durationMilliseconds: max(0, duration), grant: approval?.grant))),
                .toClient(reply),
            ]
        case .cancelled:
            return []
        }
    }

    mutating func listPage(
        fanout: Int, server: String, message: JSONValue, failure: String = "did not list tools"
    ) -> [MCPGatewayOutput] {
        guard var state = fanouts[fanout] else { return [] }
        var outputs: [MCPGatewayOutput] = []
        if upstreams[server] != nil, let tools = message["result"]?["tools"]?.arrayValue {
            state.listed[server, default: []] += tools
            state.pages[server, default: 0] += 1
            let room = max(0, Self.maximumListedTools - state.tools.count)
            if state.listed[server, default: []].count > room {
                state.listed[server] = Array(state.listed[server, default: []].prefix(room))
                outputs.append(.log("MCP tool listing exceeded \(Self.maximumListedTools) tools; truncating"))
            } else if let cursor = message["result"]?["nextCursor"]?.stringValue, cursor.isEmpty == false {
                let key = server + "\0" + cursor
                if state.seenCursors.contains(key) || state.pages[server, default: 0] >= Self.maximumListPagesPerServer {
                    outputs.append(.log("MCP server \(server) cycled or over-paged its tool list; stopping pagination"))
                } else {
                    state.seenCursors.insert(key)
                    fanouts[fanout] = state
                    let id = allocate(.list(
                        fanout: fanout, server: server, deadline: clock().addingTimeInterval(deadlines.list)))
                    return outputs + [.toUpstream(server: server, message: Self.request(
                        id: .int(id), method: "tools/list", params: .object(["cursor": .string(cursor)])))]
                }
            }
        } else {
            outputs.append(.log("MCP server \(server) \(failure)"))
        }
        if let upstream = upstreams[server] {
            let settled = settleListing(state.listed.removeValue(forKey: server) ?? [], upstream: upstream)
            state.tools += settled.tools
            outputs += settled.outputs
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
                    isError: false, reason: "searched \(state.tools.count) tools", outcome: .notRun)),
                .toClient(Self.searchResult(id: state.client, tools: state.tools, search: search)),
            ]
        }
        return outputs + [.toClient(Self.result(id: state.client, .object(["tools": .array(state.tools)])))]
    }

    /// One server's listing against its pins. The gateway never pins: a
    /// tool with no pin, or listed this session with a definition other
    /// than its pin or than an earlier listing, stays unpinned for the rest
    /// of the session. Each such tool is audited once per definition (at
    /// most `maximumChangeEvents` per server) and kept in the review queue
    /// for `rv mcp trust`. A tool whose name `servesToolName` rejects is
    /// neither listed, observed nor queued; stderr says so once per server.
    /// A tool whose schema `schemaNamesHideText` rejects is observed (so
    /// its pin is still checked) but neither listed, called nor queued;
    /// stderr says so once per server too.
    mutating func settleListing(
        _ listed: [JSONValue], upstream: Upstream
    ) -> (tools: [JSONValue], outputs: [MCPGatewayOutput]) {
        let server = upstream.definition.name
        let shownServer = MCPDisplayedText.field(server)
        var outputs: [MCPGatewayOutput] = []
        let unserved = listed.compactMap { scrub($0, for: server)["name"]?.stringValue }.filter { Self.servesToolName($0) == false }
        if let first = unserved.first, unservedNoticed.insert(server).inserted {
            let shown = MCPDisplayedText.field(MCPCallRecord.bounded(first, 64))
            outputs.append(.log(
                "MCP server \(shownServer) lists \(unserved.count) tool(s) whose names rv does not serve "
                    + "(only A-Z a-z 0-9 _ . -, at most 64 bytes), such as \"\(shown)\"; they are hidden"))
        }
        let scrubbed = listed.map { scrub($0, for: server) }
        let hidingOrder = scrubbed.filter(Self.schemaNamesHideText).compactMap { tool in
            tool["name"]?.stringValue.flatMap { Self.servesToolName($0) ? $0 : nil }
        }
        let hiding = Set(hidingOrder)
        // A tool once listed hiding stays refused until a listing shows it
        // with a definition that does not hide: a listing that omits it (a
        // partial page, an error reply, a dead upstream) clears nothing.
        let listedNames = Set(scrubbed.compactMap { $0["name"]?.stringValue })
        hidingSchemas[server] = (hidingSchemas[server] ?? []).subtracting(listedNames).union(hiding)
        if let first = hidingOrder.first, hidingSchemaNoticed.insert(server).inserted {
            // `first` conforms to `servesToolName` (ASCII, at most 64 bytes);
            // escaped and bounded anyway, as for the name notice. The
            // property name that hides text is never quoted.
            let shown = MCPDisplayedText.field(MCPCallRecord.bounded(first, 64))
            outputs.append(.log(
                "MCP server \(shownServer) lists \(hidingOrder.count) tool(s) with schema property names rv does not serve "
                    + "(control, separator or format characters), such as \"\(shown)\"; they are hidden"))
        }
        if pinning.enforced {
            var seen: [String: String] = [:]
            var definitions: [String: JSONValue] = [:]
            let known = observed[server] ?? [:]
            var tracked = known.count
            var untracked = 0
            for tool in listed {
                guard let definition = MCPToolPinStore.definition(of: scrub(tool, for: server)),
                    let name = definition["name"]?.stringValue, Self.servesToolName(name)
                else { continue }
                // Past the per-server cap a new name is never observed, so
                // it stays unverified and asks; it is not queued either.
                if known[name] == nil, seen[name] == nil {
                    guard tracked < Self.maximumTrackedTools else {
                        untracked += 1
                        continue
                    }
                    tracked += 1
                }
                let hash = MCPToolPinStore.hash(definition)
                if let earlier = seen[name] ?? observed[server]?[name], earlier != hash {
                    tainted.insert(server + "\0" + name)
                }
                if let pinned = pins?[server]?[name], pinned != hash { tainted.insert(server + "\0" + name) }
                seen[name] = hash
                definitions[name] = definition
            }
            observed[server, default: [:]].merge(seen) { _, new in new }
            // Keep only tracked hiding tools; one past the cap is refused
            // through `hidingUntracked` instead, so it never merely asks.
            if let hidden = hidingSchemas[server] {
                let tracked = hidden.filter { observed[server]?[$0] != nil }
                if tracked.count < hidden.count, hidingUntracked.insert(server).inserted {
                    outputs.append(.log(
                        "MCP server \(shownServer) lists more than \(Self.maximumTrackedTools) tools, and one past them "
                            + "names schema properties with control, separator or format characters; \(Self.untrackedHidingNotice) "
                            + "every tool of it that rv does not track until `rv mcp serve` restarts. Have the server list "
                            + "fewer tools, then restart the MCP host"))
                }
                hidingSchemas[server] = tracked
            }
            if untracked > 0, hidingUntracked.contains(server) == false, untrackedNoticed.insert(server).inserted {
                outputs.append(.log(
                    "MCP server \(shownServer) lists more than \(Self.maximumTrackedTools) tools; "
                        + "rv cannot check the rest against your trusted tools, so they always ask"))
            }
            var unpinned: [String: JSONValue] = [:]
            var untrusted = 0
            for name in seen.keys.sorted() where configuration.decision(server: upstream.definition, tool: name) != .deny {
                let status = pinStatus(server: server, tool: name)
                guard status != .pinned else { continue }
                // A hidden tool is checked against its pin above and audited
                // below, but never counted or offered for review: it would
                // not be served once trusted.
                let hidden = hiding.contains(name)
                if hidden == false { untrusted += 1 }
                let hash = seen[name] ?? ""
                let change = name + "\0" + hash
                // Offered to the review queue once per definition, again
                // only after the queue did not keep it; at most
                // `maximumTrackedChanges` per server, and the tool asks either way.
                if hidden == false, reportedChanges[server]?.contains(change) != true {
                    if (reportedChanges[server]?.count ?? 0) < Self.maximumTrackedChanges {
                        reportedChanges[server, default: []].insert(change)
                        // The pinned definition itself, listed again after another
                        // one, asks for this session but has nothing to review.
                        if pins?[server]?[name] != hash { unpinned[name] = definitions[name] }
                    } else if pins?[server]?[name] != hash, trackingFullNoticed.insert(server).inserted {
                        // Not queued, and possibly past the event budget too:
                        // say once that this session stopped queueing.
                        let reason = "MCP tool tracking is full for \(server); later changed definitions are not queued "
                            + "for review. They still ask. Restart `rv mcp serve` after `rv mcp trust`"
                        outputs.append(.log(
                            "MCP tool tracking is full for \(shownServer) (\(Self.maximumTrackedChanges) definitions this "
                                + "session); later changed definitions are not queued for review and still ask. "
                                + "Restart `rv mcp serve` after `rv mcp trust`"))
                        outputs.append(.event(AuditEvent(
                            time: clock(), kind: .mcpToolChanged, decision: .pending, subject: server,
                            reason: reason, source: "mcp-gateway", detail: ["server": server, "trackingFull": "true"])))
                    }
                }
                // Audited once per definition, even when the queue keeps
                // offering it; a later, different definition is audited anew.
                guard eventedChanges[server]?.contains(change) != true else { continue }
                let written = changeEvents[server, default: 0]
                guard written <= Self.maximumChangeEvents else { continue }
                changeEvents[server] = written + 1
                if written == Self.maximumChangeEvents {
                    outputs.append(.event(AuditEvent(
                        time: clock(), kind: .mcpToolChanged, decision: .pending, subject: server,
                        reason: "further MCP tool definition changes on this server are suppressed this session; "
                            + "they still need approval until `rv mcp trust`",
                        source: "mcp-gateway", detail: ["server": server, "suppressed": "true"])))
                    continue
                }
                eventedChanges[server, default: []].insert(change)
                var detail = ["server": server, "tool": name, "status": status.rawValue, "sha256": hash]
                if hidden { detail["hidden"] = "true" }
                outputs.append(.event(AuditEvent(
                    time: clock(), kind: .mcpToolChanged, decision: .pending, subject: "\(server)/\(name)",
                    reason: hidden
                        ? "MCP tool definition names a schema property with a control, separator or format character; "
                            + "rv does not serve it"
                        : "MCP tool definition is not the one the user trusted; calls need approval until `rv mcp trust`",
                    source: "mcp-gateway", detail: detail)))
            }
            if untrusted > 0, untrustedNoticed.insert(server).inserted {
                outputs.append(.log(untrusted == 1
                    ? "1 tool on \(shownServer) is not yet trusted; run `rv mcp trust`"
                    : "\(untrusted) tools on \(shownServer) are not yet trusted; run `rv mcp trust`"))
            }
            if unpinned.isEmpty == false {
                switch pinning.recordChanged(server, unpinned) {
                case .recorded:
                    break
                case .dropped(let names):
                    // Not kept: a later listing offers them again, without a
                    // second audit event or stderr line.
                    for name in names { reportedChanges[server]?.remove(name + "\0" + (seen[name] ?? "")) }
                    if queueNoticed.insert(server).inserted {
                        outputs.append(.log(
                            "the review queue for `rv mcp trust` is full; \(names.count) tool definitions of MCP server \(shownServer) were not kept"))
                    }
                case .failed:
                    for name in unpinned.keys { reportedChanges[server]?.remove(name + "\0" + (seen[name] ?? "")) }
                    if queueNoticed.insert(server).inserted {
                        outputs.append(.log(
                            "could not keep the untrusted tools of MCP server \(shownServer) for `rv mcp trust`"))
                    }
                }
            }
        }
        // A name refused as hidden is not listed either, whichever of its
        // entries (a clean duplicate, one on another page) is exposed.
        let shown = zip(listed, scrubbed).filter { _, tool in
            tool["name"]?.stringValue.map { hiddenRefusal(server: server, tool: $0) != nil } != true
        }
        return (shown.compactMap { exposedTool($0.0, upstream: upstream) }, outputs)
    }

    /// Why a call to `tool` on `server` is refused as hidden, or nil: it
    /// was listed with a schema `schemaNamesHideText` rejects
    /// (`hidingSchemaReason`), or its server listed such a tool past
    /// `maximumTrackedTools` and rv does not track this one
    /// (`untrackedHidingReason`).
    func hiddenRefusal(server: String, tool: String) -> String? {
        if hidingSchemas[server]?.contains(tool) == true { return Self.hidingSchemaReason }
        if hidingUntracked.contains(server), observed[server]?[tool] == nil { return Self.untrackedHidingReason }
        return nil
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

    /// Denied tools are hidden, and so is every tool whose name
    /// `servesToolName` rejects or whose schema `schemaNamesHideText`
    /// rejects. `ask` tools say so in their description,
    /// and so do tools whose arguments can change the decision. A tool that
    /// is not pinned (changed, new, or unverifiable) always asks and is
    /// listed with no upstream string but its name: its description is rv's
    /// marker, its input schema `{"type":"object"}`, it has no output
    /// schema and no annotations. For a pinned tool the prose fields (`description`, `title`,
    /// `annotations.title`, and every `schemaProseKeywords` string in its
    /// schemas) keep line breaks and backslashes and lose only hiding
    /// scalars (`MCPDisplayedText.description`); one that is not a string
    /// is dropped. Everything else is forwarded as the upstream sent it,
    /// after secret scrubbing.
    func exposedTool(_ tool: JSONValue, upstream: Upstream) -> JSONValue? {
        let scrubbed = scrub(tool, for: upstream.definition.name)
        guard let object = scrubbed.objectValue, let name = object["name"]?.stringValue, Self.servesToolName(name),
            Self.schemaNamesHideText(scrubbed) == false
        else {
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
        var walked = object
        if let marker = Self.pinMarker(pinStatus(server: upstream.definition.name, tool: name)) {
            // No upstream field but the (conforming) name: an empty object
            // schema, so the arguments an approved call forwards are the
            // client's own, and no annotations (an unreviewed
            // `readOnlyHint: true` could let a host skip its own prompt).
            var withheld = JSONObject()
            withheld["name"] = .string(listedName)
            withheld["description"] = .string(marker)
            withheld["inputSchema"] = .object(["type": .string("object")])
            return .object(withheld)
        }
        let shownDescription = MCPDisplayedText.description(rawDescription ?? "")
        walked["description"] = rawDescription.map { _ in JSONValue.string(shownDescription) }
        walked["title"] = object["title"]?.stringValue.map { JSONValue.string(MCPDisplayedText.description($0)) }
        if var annotations = object["annotations"]?.objectValue, annotations["title"] != nil {
            annotations["title"] = annotations["title"]?.stringValue.map { JSONValue.string(MCPDisplayedText.description($0)) }
            walked["annotations"] = .object(annotations)
        }
        for key in ["inputSchema", "outputSchema"] {
            if let schema = object[key] { walked[key] = Self.schemaProse(schema) }
        }
        if configuration.decision(server: upstream.definition, tool: name) == .ask {
            walked["description"] = .string("[rv: needs the user's approval] " + shownDescription)
        } else if configuration.hasArgumentRules(server: upstream.definition, tool: name) {
            walked["description"] = .string(
                "[rv: some arguments need the user's approval or are refused] " + shownDescription)
        }
        walked["name"] = .string(MCPDisplayedText.field(listedName))
        return .object(walked)
    }

    /// Keywords whose values are data, kept byte-exact: a client sends them
    /// back verbatim. A hiding scalar in a `const`, `enum`, `default` or
    /// `examples` value is an accepted residual (`rv mcp trust` showed it
    /// escaped); `dependentRequired` names properties, so
    /// `schemaNamesHideText` checks it first and serves no tool it rejects.
    static let schemaValueKeywords: Set<String> = ["const", "enum", "default", "examples", "dependentRequired"]
    /// Keywords whose members are named subschemas (or, for
    /// `dependencies`, property-name lists); a member may be called
    /// `description` or `title`.
    static let schemaMapKeywords: Set<String> = [
        "properties", "patternProperties", "$defs", "definitions", "dependentSchemas", "dependencies",
    ]
    /// Schema keywords whose string value is display text.
    static let schemaProseKeywords: Set<String> = ["description", "title", "$comment", "markdownDescription"]
    /// Why a call to a tool `schemaNamesHideText` rejects is refused.
    static let hidingSchemaReason = "rv does not serve tools whose schema property names hide text"
    /// Why a call to an untracked tool of a server in `hidingUntracked` is refused.
    static let untrackedHidingReason = "the server listed more tools than rv tracks, one of them with schema property "
        + "names that hide text, so rv does not serve its tools it does not track"
    /// The words the stderr notice for such a server uses.
    static let untrackedHidingNotice = "rv now hides and refuses"

    /// True when a tool's `inputSchema` or `outputSchema` names a property
    /// (a `properties`, `dependencies` or `dependentSchemas` member, a
    /// `required` entry, a `dependentRequired` member or entry, a
    /// `dependencies` list entry) with a scalar `MCPDisplayedText.hidesText`
    /// flags. Those names are data rv forwards exactly and a client may
    /// show raw, so rv serves no such tool, as for a name `servesToolName`
    /// rejects. A name list of another shape fails closed: every string and
    /// key in it is checked.
    static func schemaNamesHideText(_ tool: JSONValue) -> Bool {
        ["inputSchema", "outputSchema"].contains { key in tool[key].map(namesHideText) ?? false }
    }

    private static func namesHideText(_ schema: JSONValue) -> Bool {
        func hides(_ text: String) -> Bool { MCPDisplayedText.hidesText(text) }
        func anyHides(_ value: JSONValue) -> Bool {
            switch value {
            case .string(let text): return hides(text)
            case .array(let items): return items.contains(where: anyHides)
            case .object(let members): return members.entries.contains { hides($0.key) || anyHides($0.value) }
            default: return false
            }
        }
        switch schema {
        case .array(let items):
            return items.contains(where: namesHideText)
        case .object(let object):
            return object.entries.contains { entry in
                let (key, value) = entry
                switch key {
                case "required", "dependentRequired":
                    return anyHides(value)
                case "properties", "dependencies", "dependentSchemas":
                    guard let members = value.objectValue else { return anyHides(value) }
                    return members.entries.contains { member in
                        hides(member.key) || (member.value.objectValue == nil ? anyHides(member.value) : namesHideText(member.value))
                    }
                case _ where schemaValueKeywords.contains(key):
                    return false
                case _ where schemaMapKeywords.contains(key):
                    return value.objectValue?.entries.contains { namesHideText($0.value) } ?? namesHideText(value)
                default:
                    return namesHideText(value)
                }
            }
        default:
            return false
        }
    }

    /// A pinned tool's JSON Schema with every `schemaProseKeywords` string
    /// shown with hiding scalars neutralised, and such a keyword whose
    /// value is not a string dropped. `pattern` and the value keywords
    /// are left byte-exact.
    static func schemaProse(_ schema: JSONValue) -> JSONValue {
        switch schema {
        case .array(let items):
            return .array(items.map { schemaProse($0) })
        case .object(let object):
            var copy = JSONObject()
            for (key, value) in object.entries {
                if schemaValueKeywords.contains(key) {
                    copy[key] = value
                } else if schemaProseKeywords.contains(key) {
                    copy[key] = value.stringValue.map { JSONValue.string(MCPDisplayedText.description($0)) }
                } else if schemaMapKeywords.contains(key), let members = value.objectValue {
                    var mapped = JSONObject()
                    for (member, subschema) in members.entries { mapped[member] = schemaProse(subschema) }
                    copy[key] = .object(mapped)
                } else {
                    copy[key] = schemaProse(value)
                }
            }
            return .object(copy)
        default:
            return schema
        }
    }

    /// A progress notification for a call this upstream is running, rebuilt
    /// from the fields the protocol defines: the client's own token, the
    /// numbers, and a bounded, scrubbed, display-escaped `message`. Nil
    /// (dropped) when no pending call from `server` carries the token, or
    /// when `progress` (or a `total` that is present) is not a finite number
    /// spelled in at most `maximumProgressNumberBytes`. The token sent on is
    /// the one the client gave, never the upstream's copy of it. Progress
    /// that is sent on restarts the call's deadline, up to its ceiling.
    mutating func progress(from server: String, _ params: JSONValue?) -> JSONValue? {
        func runs(_ id: Int) -> Bool {
            guard case .call(let call)? = pending[id] else { return false }
            return call.server == server
        }
        func finite(_ value: JSONValue?) -> Bool {
            guard case .number(let spelling)? = value,
                spelling.utf8.count <= Self.maximumProgressNumberBytes,
                let number = Double(spelling)
            else { return false }
            return number.isFinite
        }
        guard let sent = params?["progressToken"],
            let match = progressTokens.first(where: { $0.value == sent && runs($0.key) }),
            let done = params?["progress"], finite(done)
        else { return nil }
        let id = match.key
        let token = match.value
        let total = params?["total"]
        guard total == nil || finite(total) else { return nil }
        if case .call(var call)? = pending[id] {
            call.deadline = min(clock().addingTimeInterval(callTimeout(server)), call.ceiling)
            pending[id] = .call(call)
        }
        var rebuilt = JSONObject()
        rebuilt["progressToken"] = token
        rebuilt["progress"] = done
        if let total { rebuilt["total"] = total }
        if let text = params?["message"]?.stringValue {
            rebuilt["message"] = .string(MCPCallRecord.bounded(
                MCPDisplayedText.field(scrubText(text, for: server)), Self.maximumProgressMessageBytes))
        }
        return Self.notification("notifications/progress", .object(rebuilt))
    }

    /// A tool result or upstream error, scrubbed of secrets and otherwise
    /// exactly as the upstream sent it: file contents, code, and regexes
    /// keep their newlines and backslashes. JSON escapes every control,
    /// separator, and format scalar on the wire (`JSONValue.escapedContent`).
    func clientVisibleReply(_ message: JSONValue, server: String) -> JSONValue {
        scrub(message, for: server)
    }

    mutating func upstreamExited(_ server: String) -> [MCPGatewayOutput] {
        guard upstreams[server] != nil else { return [] }
        let wasStarting = phases[server] == .starting
        // A server already failed keeps its first reason (a start that
        // timed out, then the stopped process's exit).
        if case .failed? = phases[server] {} else { phases[server] = .failed("process exited") }
        var outputs: [MCPGatewayOutput] = [.log("MCP server \(server) exited")]
        for (id, entry) in pending.sorted(by: { $0.key < $1.key }) {
            switch entry {
            case .initialize(let owner, _) where owner == server:
                pending[id] = nil
            case .list(let fanout, let owner, _) where owner == server:
                pending[id] = nil
                outputs += listPage(fanout: fanout, server: server, message: .null)
            case .call(let call) where call.server == server:
                pending[id] = nil
                progressTokens[id] = nil
                outputs.append(.audit(MCPCallRecord(
                    server: server, tool: call.tool, decision: call.approval == nil ? .allow : .ask,
                    argumentKeys: call.keys, isError: true, reason: "upstream exited",
                    outcome: .interrupted(grant: call.approval?.grant))))
                outputs.append(.toClient(Self.error(id: call.client, code: -32603, message: "MCP server \(server) exited")))
            case .cancelled(let owner, _) where owner == server:
                pending[id] = nil
            default:
                continue
            }
        }
        for (key, call) in held.filter({ $0.value.server == server }).sorted(by: { $0.key < $1.key }) {
            held[key] = nil
            outputs.append(.audit(MCPCallRecord(
                server: server, tool: call.tool, decision: .ask, argumentKeys: call.keys,
                isError: true, reason: "upstream exited", outcome: .declined(approvalID: key))))
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
    /// Bounds on what one `mcp.call` event carries from the client.
    public static let maximumAuditedKeys = 64
    public static let maximumAuditedKeyBytes = 256
    public static let maximumAuditedSubjectBytes = 512
    public static let maximumAuditedReasonBytes = 1024

    /// The unified `mcp.call` audit event. An `ask` call that was granted is
    /// `allowed`, even if it then failed; one still waiting on an approval is
    /// `pending`; one refused, by the user or by rv, is `denied`.
    public func auditEvent(time: Date = Date()) -> AuditEvent {
        let audited: AuditDecision
        switch decision {
        case .allow: audited = .allowed
        case .deny: audited = .denied
        case .ask:
            switch outcome {
            case .ran, .interrupted, .forwarding: audited = .allowed
            case .awaiting: audited = .pending
            case .declined, .notRun: audited = .denied
            }
        }
        // The client chooses the tool name and the argument names, so both
        // are bounded: one call is one audit line of bounded size.
        let keys = argumentKeys.prefix(Self.maximumAuditedKeys).map { Self.bounded($0, Self.maximumAuditedKeyBytes) }
        var detail = [
            "server": Self.bounded(server, Self.maximumAuditedSubjectBytes),
            "tool": Self.bounded(tool, Self.maximumAuditedSubjectBytes),
            "policy": decision.rawValue,
            "argumentKeys": keys.joined(separator: ","),
            "isError": isError ? "true" : "false",
        ]
        if keys != Array(argumentKeys) { detail["argumentKeysTruncated"] = "true" }
        if let approvalID { detail["approval"] = Self.bounded(approvalID, Self.maximumAuditedKeyBytes) }
        if let approvedVia { detail["approvedVia"] = approvedVia.rawValue }
        if let durationMilliseconds { detail["durationMs"] = String(durationMilliseconds) }
        if case .forwarding = outcome { detail["stage"] = "forward" }
        return AuditEvent(
            time: time, kind: .mcpCall, decision: audited,
            subject: Self.bounded("\(server)/\(tool)", Self.maximumAuditedSubjectBytes),
            reason: reason.map { Self.bounded($0, Self.maximumAuditedReasonBytes) },
            source: "mcp-gateway", detail: detail)
    }

    /// The longest prefix of whole scalars that fits in `bytes` UTF-8 bytes.
    static func bounded(_ text: String, _ bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var kept = String.UnicodeScalarView()
        var used = 0
        for scalar in text.unicodeScalars {
            let size = String(scalar).utf8.count
            guard used + size <= bytes else { break }
            kept.append(scalar)
            used += size
        }
        return String(kept)
    }
}
