import Foundation
import RVDomain
import RVFileStore
import RVIsolation
import RVPolicy

public enum MCPToolDecision: String, Sendable, Equatable, CaseIterable {
    case allow
    case ask
    case deny

    var strictness: Int {
        switch self {
        case .allow: 0
        case .ask: 1
        case .deny: 2
        }
    }
}

/// The strictest matching glob or argument rule (deny > ask > allow), else
/// `default`, else the caller's fallback. `MCPConfiguration.decision`
/// always passes a deny fallback and overwrites `default`, so a written
/// user default never decides; organization policy composes separately.
public struct MCPToolPolicy: Sendable, Equatable {
    public var defaultDecision: MCPToolDecision?
    public var allow: [String]
    public var ask: [String]
    public var deny: [String]
    /// Rule objects from the allow/ask/deny lists, in that order.
    public var rules: [ToolArgumentRule.Decided]

    public init(
        defaultDecision: MCPToolDecision? = nil, allow: [String] = [], ask: [String] = [], deny: [String] = [],
        rules: [ToolArgumentRule.Decided] = []
    ) {
        self.defaultDecision = defaultDecision
        self.allow = allow
        self.ask = ask
        self.deny = deny
        self.rules = rules
    }

    /// Without arguments (a listing), only plain globs apply.
    public func decision(for tool: String, arguments: JSONValue? = nil, fallback: MCPToolDecision) -> MCPToolDecision {
        var matched: [MCPToolDecision] = []
        if deny.contains(where: { MCPGlob.matches($0, tool) }) { matched.append(.deny) }
        if ask.contains(where: { MCPGlob.matches($0, tool) }) { matched.append(.ask) }
        if allow.contains(where: { MCPGlob.matches($0, tool) }) { matched.append(.allow) }
        if let arguments, let ruled = ToolArgumentRule.strictest(rules, tool: tool, arguments: arguments.domainValue) {
            matched.append(MCPToolDecision(ruled))
        }
        return matched.max { $0.strictness < $1.strictness } ?? defaultDecision ?? fallback
    }

    public func hasArgumentRules(for tool: String) -> Bool {
        rules.contains { $0.rule.namesTool(tool) }
    }
}

extension MCPToolDecision {
    init(_ decision: ManagedPolicy.Decision) {
        switch decision {
        case .allow: self = .allow
        case .ask: self = .ask
        case .deny: self = .deny
        }
    }
}

/// What the `sandbox.hosts` proxy does with any other host: refuse it
/// (`enforce`, the default) or let it through and log a would-be block
/// (`audit`), for trialling a tighter list.
public enum MCPSandboxEnforcement: String, Sendable, Equatable {
    case enforce
    case audit
}

public struct MCPSandboxPolicy: Sendable, Equatable {
    public static let maximumHosts = 32

    public var network: Bool
    public var writable: [String]
    /// Exact DNS names reached through a per-server allowlist proxy; the
    /// cage itself can dial only that proxy.
    public var hosts: [String]
    /// `sandbox.allowed_ips`: owner-set private networks per listed host.
    /// A host here may also reach non-public addresses, and only when its
    /// whole answer falls inside its list; other hosts stay public-only.
    public var allowedIPs: [String: EgressAllowedIPs]
    /// As written; `MCPConfiguration.sandboxEnforcement(for:integrity:)` is what applies.
    public var enforcement: MCPSandboxEnforcement

    public init(
        network: Bool = true, writable: [String] = [], hosts: [String] = [],
        allowedIPs: [String: EgressAllowedIPs] = [:], enforcement: MCPSandboxEnforcement = .enforce
    ) {
        self.network = network
        self.writable = writable
        self.hosts = hosts
        self.allowedIPs = allowedIPs
        self.enforcement = enforcement
    }
}

/// Legacy profile key. Strict semantics are unconditional now: tools no
/// list names are denied, local servers need a sandbox, and a sandbox
/// reaches the network only through `sandbox.hosts`. Both values still
/// decode so existing files need no migration; the value no longer
/// changes any decision.
public enum MCPProfile: String, Sendable, Equatable {
    case standard
    case strict
}

public enum MCPRemoteTransport: String, Sendable, Equatable {
    /// Streamable HTTP (MCP 2025-03-26 and later).
    case http
    /// The 2024-11-05 HTTP+SSE transport.
    case sse
}

/// A server reached over HTTP. The gateway holds the headers (and any OAuth
/// token), so the agent's host config never sees them.
public struct MCPRemoteServer: Sendable, Equatable {
    public var url: URL
    /// Values may hold `${secret:NAME}`.
    public var headers: [String: String]
    public var transport: MCPRemoteTransport

    public init(url: URL, headers: [String: String] = [:], transport: MCPRemoteTransport = .http) {
        self.url = url
        self.headers = headers
        self.transport = transport
    }

    public var secretNames: [String] {
        Set(headers.values.flatMap { MCPSecretReference.names(in: $0) ?? [] }).sorted()
    }

    /// Headers the transport or URLSession owns.
    static let managedHeaders: Set<String> = [
        "mcp-session-id", "mcp-protocol-version", "host", "content-length", "content-type", "transfer-encoding",
        "connection", "accept", "last-event-id",
    ]
    static let maximumHeaders = 32

    /// https anywhere, http only to loopback; no credentials or fragment.
    /// A thin adapter over the one classification in `SecretFreeEndpoint`:
    /// this map keeps the MCP sentences, the seam keeps the decision.
    public static func endpointProblem(_ url: URL) -> String? {
        switch SecretFreeEndpoint.problemKind(for: url) {
        case nil: nil
        case .malformed, .scheme: "must be https (http only to localhost)"
        case .nonCanonicalHost: "must name its host as a canonical IP address or DNS name"
        case .credentials: "must be given without credentials (send them as headers with ${secret:NAME})"
        case .fragment: "must not have a fragment"
        case .hostSecret: "must not carry a secret in its host (send it as a header with ${secret:NAME})"
        case .querySecret: "must not carry a secret in its query (send it as a header with ${secret:NAME})"
        case .pathSecret, .userinfoSpelling:
            "must not carry a secret in its path (send it as a header with ${secret:NAME})"
        }
    }

    /// Parsed loopback, owned by `SecretFreeEndpoint`; kept here because
    /// MCPOAuth's endpoint binding asks it of a server host directly.
    static func isLoopback(_ host: String) -> Bool {
        SecretFreeEndpoint.isLoopback(host)
    }
}

public struct MCPServerDefinition: Sendable, Equatable {
    public var name: String
    public var description: String?
    /// Empty for a remote server.
    public var command: String
    public var args: [String]
    /// Literal, non-secret values for the upstream's environment.
    public var environment: [String: String]
    /// Upstream environment variable → rv secret name (Phase 2 `secrets.json`).
    public var secrets: [String: String]
    /// Secret names the server gets as per-launch placeholders instead of
    /// real values; the variables come from each secret's definition.
    public var placeholders: [String]
    public var tools: MCPToolPolicy
    public var sandbox: MCPSandboxPolicy?
    /// Set instead of `command`; the decoder refuses process keys beside it.
    public var remote: MCPRemoteServer?
    /// How long one `tools/call` may go unanswered; its progress restarts it.
    public var callTimeoutSeconds: Int = MCPServerDefinition.defaultCallTimeoutSeconds

    /// How long the server may take to answer `initialize`.
    public var startTimeoutSeconds: Int = MCPServerDefinition.defaultStartTimeoutSeconds

    public static let defaultCallTimeoutSeconds = 300
    public static let callTimeoutRange = 1...86400
    public static let defaultStartTimeoutSeconds = 60
    public static let startTimeoutRange = 1...600

    public init(name: String, description: String? = nil, remote: MCPRemoteServer, tools: MCPToolPolicy = MCPToolPolicy()) {
        self.init(name: name, description: description, command: "", tools: tools)
        self.remote = remote
    }

    public init(
        name: String,
        description: String? = nil,
        command: String,
        args: [String] = [],
        environment: [String: String] = [:],
        secrets: [String: String] = [:],
        tools: MCPToolPolicy = MCPToolPolicy(),
        sandbox: MCPSandboxPolicy? = nil,
        placeholders: [String] = []
    ) {
        self.name = name
        self.description = description
        self.command = command
        self.args = args
        self.environment = environment
        self.secrets = secrets
        self.placeholders = placeholders
        self.tools = tools
        self.sandbox = sandbox
    }
}

public enum MCPConfigurationError: Error, Sendable, Equatable {
    case unsafeFile(String)
    case unreadable
    case oversized
    case invalid(String)

    public var message: String {
        switch self {
        case .unsafeFile(let reason): "mcp.json is unsafe (\(reason)); it must be a regular file only you can write"
        case .unreadable: "mcp.json could not be read or written"
        case .oversized: "mcp.json is larger than \(MCPConfiguration.maximumBytes) bytes"
        case .invalid(let reason): "mcp.json is invalid: \(reason)"
        }
    }
}

/// `search` lists only `rv_search_tools` and `rv_call_tool`, so a client
/// with many servers does not load every tool schema up front.
public enum MCPToolMode: String, Sendable, Equatable {
    case direct
    case search
}

public struct MCPConfiguration: Sendable, Equatable {
    public static let fileName = MCPHostConfigPaths.gatewayConfigFileName
    public static let maximumBytes = 1024 * 1024
    public static let maximumServers = 128

    public var defaultDecision: MCPToolDecision
    public var servers: [MCPServerDefinition]
    public var direct: [String]
    public var blocked: [String]
    public var toolMode: MCPToolMode = .direct
    public var profile: MCPProfile = .standard
    /// Organization restrictions layered over this file; never encoded.
    public var managed: ManagedPolicy?
    /// The file was not written or trusted through rv; never encoded. Its
    /// `allow` decisions become `ask`, so an outside edit can only tighten.
    public var untrusted = false

    public init(
        defaultDecision: MCPToolDecision = .deny,
        servers: [MCPServerDefinition] = [],
        direct: [String] = [],
        blocked: [String] = []
    ) {
        self.defaultDecision = defaultDecision
        self.servers = servers
        self.direct = direct
        self.blocked = blocked
    }

    public func server(named name: String) -> MCPServerDefinition? {
        servers.first { $0.name == name }
    }

    /// The stricter of the user's rules and the organization's. Without
    /// arguments (a listing), argument rules do not apply. Written
    /// `defaultDecision` / `tools.default` values are inert: a tool no
    /// glob or argument rule names is denied.
    public func decision(server: MCPServerDefinition, tool: String, arguments: JSONValue? = nil) -> MCPToolDecision {
        var tools = server.tools
        tools.defaultDecision = .deny
        var user = tools.decision(for: tool, arguments: arguments, fallback: .deny)
        if untrusted, user == .allow { user = .ask }
        guard let organization = organizationDecision(server: server.name, tool: tool, arguments: arguments) else {
            return user
        }
        return [user, organization].max { $0.strictness < $1.strictness } ?? user
    }

    public func organizationDecision(server: String, tool: String, arguments: JSONValue? = nil) -> MCPToolDecision? {
        managed.map { MCPToolDecision($0.mcpDecision(server: server, tool: tool, arguments: arguments?.domainValue)) }
    }

    /// Whether some call to this tool could be decided differently by its arguments.
    public func hasArgumentRules(server: MCPServerDefinition, tool: String) -> Bool {
        server.tools.hasArgumentRules(for: tool) || managed?.mcpHasArgumentRules(server: server.name, tool: tool) == true
    }

    /// The enforcement `rv mcp serve` gives a server's `sandbox.hosts`. Audit
    /// loosens the owner's own list, so it needs positive proof: `integrity`
    /// must be `.trusted` (the signature over these bytes verified) and no
    /// organization policy may be installed. Anything else enforces.
    public func sandboxEnforcement(
        for server: MCPServerDefinition, integrity: MCPIntegrityStatus
    ) -> MCPSandboxEnforcement {
        guard let sandbox = server.sandbox, sandbox.hosts.isEmpty == false, sandbox.enforcement == .audit,
            integrity == .trusted, untrusted == false, managed == nil
        else { return .enforce }
        return .audit
    }

    public func isBlocked(_ server: String) -> Bool {
        blocked.contains(server) || managed?.isServerBlocked(server) == true
    }

    public func isDirect(_ server: String) -> Bool {
        managed?.mcp.allowDirect != false && direct.contains(server)
    }

    public static func fileURL(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// A missing file is an empty configuration.
    public static func load(configDirectory: URL) -> Result<MCPConfiguration, MCPConfigurationError> {
        switch OwnerOnlyFile.read(fileURL(configDirectory: configDirectory), maximumBytes: maximumBytes) {
        case .success(let data?): decode(data)
        case .success(nil): .success(MCPConfiguration())
        case .failure(.unsafe(let reason)): .failure(.unsafeFile(reason))
        case .failure(.oversized): .failure(.oversized)
        case .failure(.unreadable): .failure(.unreadable)
        }
    }

    /// Writes and signs mcp.json (`MCPIntegrity`), so `rv mcp check` knows rv wrote it.
    public func write(configDirectory: URL, signing: MCPApprovalSigning) -> Result<Void, MCPConfigurationError> {
        let data = Data(encoded().prettyText.utf8)
        if case .failure(let error) = Self.decode(data) { return .failure(error) }
        guard OwnerOnlyFile.write(data, to: Self.fileURL(configDirectory: configDirectory)),
            MCPIntegrity.sign(data, configDirectory: configDirectory, signing: signing)
        else {
            return .failure(.unreadable)
        }
        return .success(())
    }

    public static func decode(_ data: Data) -> Result<MCPConfiguration, MCPConfigurationError> {
        guard data.count <= maximumBytes else { return .failure(.oversized) }
        let root: JSONValue
        do {
            root = try JSONValue.parse(data, maximumDepth: 16)
        } catch JSONParseError.duplicateKey {
            return .failure(.invalid("repeats a JSON key"))
        } catch {
            return .failure(.invalid("not valid JSON"))
        }
        do {
            return .success(try MCPConfigurationDecoding.configuration(root))
        } catch let error as MCPConfigurationError {
            return .failure(error)
        } catch {
            return .failure(.invalid("unreadable"))
        }
    }

    public func encoded() -> JSONValue {
        var root = JSONObject()
        root["version"] = .int(1)
        root["defaultDecision"] = .string(defaultDecision.rawValue)
        if toolMode != .direct { root["toolMode"] = .string(toolMode.rawValue) }
        if profile != .standard { root["profile"] = .string(profile.rawValue) }
        root["servers"] = .array(servers.map(Self.encode))
        if direct.isEmpty == false { root["direct"] = .array(direct.map(JSONValue.string)) }
        if blocked.isEmpty == false { root["blocked"] = .array(blocked.map(JSONValue.string)) }
        return .object(root)
    }

    private static func encode(_ server: MCPServerDefinition) -> JSONValue {
        var object = JSONObject()
        object["name"] = .string(server.name)
        if let description = server.description { object["description"] = .string(description) }
        if let remote = server.remote {
            object["url"] = .string(remote.url.absoluteString)
            if remote.headers.isEmpty == false { object["headers"] = stringMap(remote.headers) }
            if remote.transport != .http { object["transport"] = .string(remote.transport.rawValue) }
        } else {
            object["command"] = .string(server.command)
        }
        if server.args.isEmpty == false { object["args"] = .array(server.args.map(JSONValue.string)) }
        if server.environment.isEmpty == false { object["env"] = stringMap(server.environment) }
        if server.secrets.isEmpty == false { object["secrets"] = stringMap(server.secrets) }
        if server.placeholders.isEmpty == false { object["placeholders"] = .array(server.placeholders.map(JSONValue.string)) }
        var tools = JSONObject()
        if let decision = server.tools.defaultDecision { tools["default"] = .string(decision.rawValue) }
        for (key, globs, decision) in [
            ("allow", server.tools.allow, ManagedPolicy.Decision.allow), ("ask", server.tools.ask, .ask),
            ("deny", server.tools.deny, .deny),
        ] {
            let rules = server.tools.rules.filter { $0.decision == decision }.map { JSONValue(domain: $0.rule.encoded) }
            if globs.isEmpty == false || rules.isEmpty == false { tools[key] = .array(globs.map(JSONValue.string) + rules) }
        }
        if tools.isEmpty == false { object["tools"] = .object(tools) }
        if let sandbox = server.sandbox {
            var value = JSONObject()
            value["network"] = .bool(sandbox.network)
            if sandbox.writable.isEmpty == false { value["writable"] = .array(sandbox.writable.map(JSONValue.string)) }
            if sandbox.hosts.isEmpty == false { value["hosts"] = .array(sandbox.hosts.map(JSONValue.string)) }
            if sandbox.enforcement == .audit { value["enforcement"] = .string(sandbox.enforcement.rawValue) }
            if sandbox.allowedIPs.isEmpty == false {
                var ranges = JSONObject()
                for host in sandbox.allowedIPs.keys.sorted() {
                    ranges[host] = sandbox.allowedIPs[host].map { .array($0.entries.map(JSONValue.string)) }
                }
                value["allowed_ips"] = .object(ranges)
            }
            object["sandbox"] = .object(value)
        }
        if server.callTimeoutSeconds != MCPServerDefinition.defaultCallTimeoutSeconds {
            object["callTimeoutSeconds"] = .int(server.callTimeoutSeconds)
        }
        if server.startTimeoutSeconds != MCPServerDefinition.defaultStartTimeoutSeconds {
            object["startTimeoutSeconds"] = .int(server.startTimeoutSeconds)
        }
        return .object(object)
    }

    private static func stringMap(_ map: [String: String]) -> JSONValue {
        var object = JSONObject()
        for key in map.keys.sorted() { object[key] = map[key].map(JSONValue.string) }
        return .object(object)
    }
}

enum MCPConfigurationDecoding {
    static func configuration(_ root: JSONValue) throws -> MCPConfiguration {
        let object = try objectValue(root, "top level")
        try allowOnly(object, ["version", "defaultDecision", "toolMode", "profile", "servers", "direct", "blocked"], "top level")
        guard object["version"]?.intValue == 1 else { throw MCPConfigurationError.invalid("version must be 1") }
        var configuration = MCPConfiguration()
        if let raw = object["defaultDecision"] {
            configuration.defaultDecision = try decision(raw, "defaultDecision")
        }
        if let raw = object["toolMode"] {
            guard let mode = raw.stringValue.flatMap(MCPToolMode.init(rawValue:)) else {
                throw MCPConfigurationError.invalid(#"toolMode must be "direct" or "search""#)
            }
            configuration.toolMode = mode
        }
        if let raw = object["profile"] {
            guard let profile = raw.stringValue.flatMap(MCPProfile.init(rawValue:)) else {
                throw MCPConfigurationError.invalid(#"profile must be "standard" or "strict""#)
            }
            configuration.profile = profile
        }
        let servers = try object["servers"].map { value -> [JSONValue] in
            guard let items = value.arrayValue else { throw MCPConfigurationError.invalid("servers must be an array") }
            return items
        } ?? []
        guard servers.count <= MCPConfiguration.maximumServers else {
            throw MCPConfigurationError.invalid("more than \(MCPConfiguration.maximumServers) servers")
        }
        configuration.servers = try servers.map(server)
        configuration.direct = try names(object["direct"], "direct")
        configuration.blocked = try names(object["blocked"], "blocked")

        var seen = Set<String>()
        for name in configuration.servers.map(\.name) where seen.insert(name).inserted == false {
            throw MCPConfigurationError.invalid("server \(name) is defined twice")
        }
        for name in configuration.blocked where seen.contains(name) || configuration.direct.contains(name) {
            throw MCPConfigurationError.invalid("\(name) is both blocked and allowed")
        }
        for name in configuration.direct where seen.contains(name) {
            throw MCPConfigurationError.invalid("\(name) is both a gateway server and direct")
        }
        return configuration
    }

    private static func server(_ value: JSONValue) throws -> MCPServerDefinition {
        let object = try objectValue(value, "server")
        guard let name = object["name"]?.stringValue, isServerName(name) else {
            throw MCPConfigurationError.invalid("server name must be 1-64 of A-Z a-z 0-9 . _ -")
        }
        let context = "server \(name)"
        if object["url"] != nil {
            guard object["command"] == nil else { throw MCPConfigurationError.invalid("\(context) has both command and url") }
            guard object["placeholders"] == nil else {
                throw MCPConfigurationError.invalid("\(context) is remote; placeholders are only for local (command) servers")
            }
            try allowOnly(
                object, ["name", "description", "url", "headers", "transport", "tools", "callTimeoutSeconds", "startTimeoutSeconds"],
                context)
            var definition = MCPServerDefinition(name: name, remote: try remote(object, context))
            definition.description = try description(object, context)
            if let raw = object["tools"] { definition.tools = try tools(raw, context) }
            definition.callTimeoutSeconds = try callTimeout(object, context)
            definition.startTimeoutSeconds = try startTimeout(object, context)
            return definition
        }
        try allowOnly(
            object,
            [
                "name", "description", "command", "args", "env", "secrets", "placeholders", "tools", "sandbox",
                "callTimeoutSeconds", "startTimeoutSeconds",
            ],
            context)
        guard let command = object["command"]?.stringValue, command.isEmpty == false, command.contains("\0") == false else {
            throw MCPConfigurationError.invalid("\(context) needs a command")
        }
        var definition = MCPServerDefinition(name: name, command: command)
        definition.description = try description(object, context)
        if let raw = object["args"] {
            guard let args = raw.stringArray else { throw MCPConfigurationError.invalid("\(context) args must be strings") }
            for arg in args {
                guard let names = MCPSecretReference.names(in: arg), names.allSatisfy(SecretsConfiguration.isVariableName) else {
                    throw MCPConfigurationError.invalid("\(context) has a malformed ${secret:NAME} in its args")
                }
            }
            definition.args = args
        }
        definition.environment = try variableMap(object["env"], "\(context) env")
        definition.secrets = try variableMap(object["secrets"], "\(context) secrets")
        for (variable, secret) in definition.secrets {
            guard SecretsConfiguration.isVariableName(secret) else {
                throw MCPConfigurationError.invalid("\(context) secrets.\(variable) names an invalid secret")
            }
            guard definition.environment[variable] == nil else {
                throw MCPConfigurationError.invalid("\(context) sets \(variable) in both env and secrets")
            }
        }
        definition.placeholders = try placeholders(object["placeholders"], context)
        let realValues = Set(definition.secrets.values)
            .union(definition.args.flatMap { MCPSecretReference.names(in: $0) ?? [] })
        for name in definition.placeholders where realValues.contains(name) {
            throw MCPConfigurationError.invalid(
                "\(context) gets secret \(name) as its real value (secrets or args) and as a placeholder; list it in one")
        }
        if let raw = object["tools"] { definition.tools = try tools(raw, context) }
        if let raw = object["sandbox"] { definition.sandbox = try sandbox(raw, context) }
        definition.callTimeoutSeconds = try callTimeout(object, context)
        definition.startTimeoutSeconds = try startTimeout(object, context)
        return definition
    }

    private static func callTimeout(_ object: JSONObject, _ context: String) throws -> Int {
        try seconds(
            object, "callTimeoutSeconds", MCPServerDefinition.callTimeoutRange,
            default: MCPServerDefinition.defaultCallTimeoutSeconds, context)
    }

    private static func startTimeout(_ object: JSONObject, _ context: String) throws -> Int {
        try seconds(
            object, "startTimeoutSeconds", MCPServerDefinition.startTimeoutRange,
            default: MCPServerDefinition.defaultStartTimeoutSeconds, context)
    }

    /// Whole seconds in `range`; absent is the default.
    private static func seconds(
        _ object: JSONObject, _ key: String, _ range: ClosedRange<Int>, default fallback: Int, _ context: String
    ) throws -> Int {
        guard let raw = object[key] else { return fallback }
        guard let seconds = raw.intValue, range.contains(seconds) else {
            throw MCPConfigurationError.invalid(
                "\(context) \(key) must be a whole number of seconds from \(range.lowerBound) to \(range.upperBound)")
        }
        return seconds
    }

    /// Distinct secret names, at most as many as secrets.json can hold.
    private static func placeholders(_ value: JSONValue?, _ context: String) throws -> [String] {
        guard let value else { return [] }
        guard let names = value.stringArray, names.allSatisfy(SecretsConfiguration.isVariableName) else {
            throw MCPConfigurationError.invalid("\(context) placeholders must be an array of secret names")
        }
        guard names.count <= SecretsConfiguration.maximumSecrets else {
            throw MCPConfigurationError.invalid(
                "\(context) placeholders has more than \(SecretsConfiguration.maximumSecrets) secrets")
        }
        var seen = Set<String>()
        for name in names where seen.insert(name).inserted == false {
            throw MCPConfigurationError.invalid("\(context) placeholders lists \(name) twice")
        }
        return names
    }

    private static func description(_ object: JSONObject, _ context: String) throws -> String? {
        guard let raw = object["description"] else { return nil }
        guard let text = raw.stringValue else { throw MCPConfigurationError.invalid("\(context) description must be a string") }
        return text
    }

    private static func remote(_ object: JSONObject, _ context: String) throws -> MCPRemoteServer {
        guard let text = object["url"]?.stringValue, let url = URL(string: text) else {
            throw MCPConfigurationError.invalid("\(context) url must be https (http only to localhost)")
        }
        if let problem = MCPRemoteServer.endpointProblem(url) {
            throw MCPConfigurationError.invalid("\(context) url \(problem)")
        }
        var remote = MCPRemoteServer(url: url)
        if let raw = object["transport"] {
            guard let transport = raw.stringValue.flatMap(MCPRemoteTransport.init(rawValue:)) else {
                throw MCPConfigurationError.invalid(#"\#(context) transport must be "http" or "sse""#)
            }
            remote.transport = transport
        }
        guard let raw = object["headers"] else { return remote }
        guard let headers = raw.objectValue else { throw MCPConfigurationError.invalid("\(context) headers must be an object") }
        guard headers.keys.count <= MCPRemoteServer.maximumHeaders else {
            throw MCPConfigurationError.invalid("\(context) has more than \(MCPRemoteServer.maximumHeaders) headers")
        }
        for (name, value) in headers.entries {
            guard isHeaderName(name) else {
                throw MCPConfigurationError.invalid("\(context) header name \(name) is not a valid HTTP header name")
            }
            guard MCPRemoteServer.managedHeaders.contains(name.lowercased()) == false else {
                throw MCPConfigurationError.invalid("\(context) headers: rv sets \(name) itself")
            }
            guard let text = value.stringValue else {
                throw MCPConfigurationError.invalid("\(context) header \(name) must be a string")
            }
            guard text.unicodeScalars.allSatisfy({ $0 != "\r" && $0 != "\n" && $0 != "\0" }) else {
                throw MCPConfigurationError.invalid("\(context) header \(name) holds a line break or NUL")
            }
            guard let names = MCPSecretReference.names(in: text), names.allSatisfy(SecretsConfiguration.isVariableName) else {
                throw MCPConfigurationError.invalid("\(context) header \(name) has a malformed ${secret:NAME}")
            }
            remote.headers[name] = text
        }
        return remote
    }

    /// RFC 9110 token characters.
    static func isHeaderName(_ name: String) -> Bool {
        (1...128).contains(name.utf8.count)
            && name.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar))
            }
    }

    private static func tools(_ value: JSONValue, _ context: String) throws -> MCPToolPolicy {
        let object = try objectValue(value, "\(context) tools")
        try allowOnly(object, ["default", "allow", "ask", "deny"], "\(context) tools")
        var policy = MCPToolPolicy()
        if let raw = object["default"] { policy.defaultDecision = try decision(raw, "\(context) tools.default") }
        for decision in [ManagedPolicy.Decision.allow, .ask, .deny] {
            let (globs, rules) = try toolRules(object[decision.rawValue], decision: decision, "\(context) tools.\(decision.rawValue)")
            switch decision {
            case .allow: policy.allow = globs
            case .ask: policy.ask = globs
            case .deny: policy.deny = globs
            }
            policy.rules += rules
        }
        return policy
    }

    private static func toolRules(
        _ value: JSONValue?, decision: ManagedPolicy.Decision, _ context: String
    ) throws -> ([String], [ToolArgumentRule.Decided]) {
        guard let value else { return ([], []) }
        guard let items = value.arrayValue else { throw MCPConfigurationError.invalid("\(context) must be an array") }
        var globs: [String] = []
        var rules: [ToolArgumentRule.Decided] = []
        for item in items {
            if let glob = item.stringValue, glob.isEmpty == false, glob.count <= 256 {
                globs.append(glob)
            } else if item.objectValue != nil {
                do {
                    rules.append(.init(decision: decision, rule: try ToolArgumentRule.decode(item.domainValue)))
                } catch let error as ToolArgumentRuleError {
                    throw MCPConfigurationError.invalid("\(context): \(error.message)")
                }
            } else {
                throw MCPConfigurationError.invalid("\(context) must hold non-empty strings or rule objects")
            }
        }
        return (globs, rules)
    }

    private static func sandbox(_ value: JSONValue, _ context: String) throws -> MCPSandboxPolicy {
        let object = try objectValue(value, "\(context) sandbox")
        try allowOnly(object, ["network", "writable", "hosts", "allowed_ips", "enforcement"], "\(context) sandbox")
        var policy = MCPSandboxPolicy()
        if let raw = object["network"] {
            guard let flag = raw.boolValue else { throw MCPConfigurationError.invalid("\(context) sandbox.network must be true or false") }
            policy.network = flag
        }
        if let raw = object["writable"] {
            guard let paths = raw.stringArray,
                paths.allSatisfy({ $0.hasPrefix("/") || $0.hasPrefix("~/") })
            else {
                throw MCPConfigurationError.invalid("\(context) sandbox.writable must be absolute or ~/ paths")
            }
            policy.writable = paths
        }
        if let raw = object["hosts"] {
            guard let hosts = raw.stringArray else {
                throw MCPConfigurationError.invalid("\(context) sandbox.hosts must be an array of host names")
            }
            guard hosts.count <= MCPSandboxPolicy.maximumHosts else {
                throw MCPConfigurationError.invalid("\(context) sandbox.hosts has more than \(MCPSandboxPolicy.maximumHosts) hosts")
            }
            for host in hosts where isHostName(host.lowercased()) == false {
                throw MCPConfigurationError.invalid(
                    "\(context) sandbox.hosts: \(host) is not a host name (exact DNS names; no scheme, port, wildcard or IP)")
            }
            if hosts.isEmpty == false {
                if object["network"]?.boolValue == true {
                    throw MCPConfigurationError.invalid("\(context) sandbox.hosts already limits the network; drop network: true")
                }
                policy.network = false
            }
            var seen = Set<String>()
            policy.hosts = hosts.map { $0.lowercased() }.filter { seen.insert($0).inserted }
        }
        if let raw = object["allowed_ips"] {
            policy.allowedIPs = try allowedIPs(raw, hosts: policy.hosts, context)
        }
        if let raw = object["enforcement"] {
            guard let text = raw.stringValue, let enforcement = MCPSandboxEnforcement(rawValue: text) else {
                throw MCPConfigurationError.invalid(#"\#(context) sandbox.enforcement must be "enforce" or "audit""#)
            }
            guard enforcement == .enforce || policy.hosts.isEmpty == false else {
                throw MCPConfigurationError.invalid("\(context) sandbox.enforcement audit needs sandbox.hosts to audit")
            }
            policy.enforcement = enforcement
        }
        return policy
    }

    /// `sandbox.allowed_ips`: `{"<host>": ["<cidr>", ...]}`. Every key must
    /// be one of `sandbox.hosts` and every entry must parse; any problem
    /// refuses the whole file, so a bad range never drops silently.
    private static func allowedIPs(
        _ value: JSONValue, hosts: [String], _ context: String
    ) throws -> [String: EgressAllowedIPs] {
        guard let object = value.objectValue else {
            throw MCPConfigurationError.invalid(
                "\(context) sandbox.allowed_ips must map a host from sandbox.hosts to a list of IP networks")
        }
        var ranges: [String: EgressAllowedIPs] = [:]
        for key in object.keys.sorted() {
            let host = key.lowercased()
            guard hosts.contains(host) else {
                throw MCPConfigurationError.invalid(
                    "\(context) sandbox.allowed_ips: \(key) is not in sandbox.hosts; list the host there too")
            }
            guard ranges[host] == nil else {
                throw MCPConfigurationError.invalid("\(context) sandbox.allowed_ips names \(host) twice")
            }
            guard let entries = object[key]?.stringArray else {
                throw MCPConfigurationError.invalid(
                    "\(context) sandbox.allowed_ips.\(key) must be an array of IP addresses or CIDR networks")
            }
            do throws(EgressAllowedIPError) {
                ranges[host] = try EgressAllowedIPs(parsing: entries)
            } catch {
                throw MCPConfigurationError.invalid("\(context) sandbox.allowed_ips.\(key): \(error.message)")
            }
        }
        return ranges
    }

    /// Two or more LDH labels, the last not numeric: no IPs, no `localhost`.
    static func isHostName(_ name: String) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name.utf8.count <= 253, labels.count >= 2, labels.last?.allSatisfy(\.isNumber) == false else { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.count) && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private static func decision(_ value: JSONValue, _ context: String) throws -> MCPToolDecision {
        guard let raw = value.stringValue, let decision = MCPToolDecision(rawValue: raw) else {
            throw MCPConfigurationError.invalid("\(context) must be allow, ask or deny")
        }
        return decision
    }

    private static func names(_ value: JSONValue?, _ context: String) throws -> [String] {
        guard let value else { return [] }
        guard let items = value.stringArray, items.allSatisfy(isServerName) else {
            throw MCPConfigurationError.invalid("\(context) must be server names")
        }
        return items
    }

    private static func variableMap(_ value: JSONValue?, _ context: String) throws -> [String: String] {
        guard let value else { return [:] }
        guard let object = value.objectValue else { throw MCPConfigurationError.invalid("\(context) must be an object") }
        var map: [String: String] = [:]
        for (key, raw) in object.entries {
            guard SecretsConfiguration.isVariableName(key), let text = raw.stringValue, text.contains("\0") == false else {
                throw MCPConfigurationError.invalid(
                    "\(context).\(MCPDisplayedText.field(key)) must be a variable name with a string value")
            }
            map[key] = text
        }
        return map
    }

    private static func objectValue(_ value: JSONValue, _ context: String) throws -> JSONObject {
        guard let object = value.objectValue else { throw MCPConfigurationError.invalid("\(context) must be an object") }
        return object
    }

    private static func allowOnly(_ object: JSONObject, _ keys: Set<String>, _ context: String) throws {
        if let unknown = object.keys.first(where: { keys.contains($0) == false }) {
            throw MCPConfigurationError.invalid("\(context) has unknown key \(MCPDisplayedText.field(unknown))")
        }
    }

    static func isServerName(_ name: String) -> Bool {
        (1...64).contains(name.count)
            && name.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
                    || scalar == "." || scalar == "_" || scalar == "-"
            }
    }
}

/// `*` matches any run, `?` one character. Everything else is literal.
public enum MCPGlob {
    public static func matches(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

/// `${secret:NAME}` in an mcp.json value. In a remote server's headers it is
/// replaced with the rv secret's value. In a local server's args it is
/// refused (`MCPLaunchPlanner.argumentSecret`): `ps` shows arguments to
/// every user, so a local server gets secrets only as environment variables.
public enum MCPSecretReference {
    static let opener = "${secret:"

    /// Names referenced by `arg`; nil when a reference is unterminated or empty.
    public static func names(in arg: String) -> [String]? {
        var names: [String] = []
        var rest = Substring(arg)
        while let start = rest.range(of: opener) {
            guard let end = rest[start.upperBound...].firstIndex(of: "}") else { return nil }
            let name = String(rest[start.upperBound..<end])
            guard name.isEmpty == false else { return nil }
            names.append(name)
            rest = rest[rest.index(after: end)...]
        }
        return names
    }

    public static func substitute(_ arg: String, values: [String: String]) -> String {
        var output = arg
        for (name, value) in values { output = output.replacingOccurrences(of: opener + name + "}", with: value) }
        return output
    }
}
