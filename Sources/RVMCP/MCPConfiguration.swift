import Foundation
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

/// deny glob > ask glob > allow glob > `default` > the file's `defaultDecision`.
public struct MCPToolPolicy: Sendable, Equatable {
    public var defaultDecision: MCPToolDecision?
    public var allow: [String]
    public var ask: [String]
    public var deny: [String]

    public init(defaultDecision: MCPToolDecision? = nil, allow: [String] = [], ask: [String] = [], deny: [String] = []) {
        self.defaultDecision = defaultDecision
        self.allow = allow
        self.ask = ask
        self.deny = deny
    }

    public func decision(for tool: String, fallback: MCPToolDecision) -> MCPToolDecision {
        if deny.contains(where: { MCPGlob.matches($0, tool) }) { return .deny }
        if ask.contains(where: { MCPGlob.matches($0, tool) }) { return .ask }
        if allow.contains(where: { MCPGlob.matches($0, tool) }) { return .allow }
        return defaultDecision ?? fallback
    }
}

public struct MCPSandboxPolicy: Sendable, Equatable {
    public var network: Bool
    public var writable: [String]

    public init(network: Bool = true, writable: [String] = []) {
        self.network = network
        self.writable = writable
    }
}

public struct MCPServerDefinition: Sendable, Equatable {
    public var name: String
    public var description: String?
    public var command: String
    public var args: [String]
    /// Literal, non-secret values for the upstream's environment.
    public var environment: [String: String]
    /// Upstream environment variable → rv secret name (Phase 2 `secrets.json`).
    public var secrets: [String: String]
    public var tools: MCPToolPolicy
    public var sandbox: MCPSandboxPolicy?

    public init(
        name: String,
        description: String? = nil,
        command: String,
        args: [String] = [],
        environment: [String: String] = [:],
        secrets: [String: String] = [:],
        tools: MCPToolPolicy = MCPToolPolicy(),
        sandbox: MCPSandboxPolicy? = nil
    ) {
        self.name = name
        self.description = description
        self.command = command
        self.args = args
        self.environment = environment
        self.secrets = secrets
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

public struct MCPConfiguration: Sendable, Equatable {
    public static let fileName = "mcp.json"
    public static let maximumBytes = 1024 * 1024
    public static let maximumServers = 128

    public var defaultDecision: MCPToolDecision
    public var servers: [MCPServerDefinition]
    public var direct: [String]
    public var blocked: [String]
    /// Organization restrictions layered over this file; never encoded.
    public var managed: ManagedPolicy?
    /// The file was not written or trusted through rv; never encoded. Its
    /// `allow` decisions become `ask`, so an outside edit can only tighten.
    public var untrusted = false

    public init(
        defaultDecision: MCPToolDecision = .ask,
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

    /// The stricter of the user's rules and the organization's.
    public func decision(server: MCPServerDefinition, tool: String) -> MCPToolDecision {
        var user = server.tools.decision(for: tool, fallback: defaultDecision)
        if untrusted, user == .allow { user = .ask }
        guard let organization = organizationDecision(server: server.name, tool: tool) else { return user }
        return [user, organization].max { $0.strictness < $1.strictness } ?? user
    }

    public func organizationDecision(server: String, tool: String) -> MCPToolDecision? {
        managed.flatMap { MCPToolDecision(rawValue: $0.mcpDecision(server: server, tool: tool).rawValue) }
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
    public func write(configDirectory: URL, signer: MCPSigner) -> Result<Void, MCPConfigurationError> {
        let data = Data(encoded().prettyText.utf8)
        if case .failure(let error) = Self.decode(data) { return .failure(error) }
        guard OwnerOnlyFile.write(data, to: Self.fileURL(configDirectory: configDirectory)),
            MCPIntegrity.sign(data, configDirectory: configDirectory, signer: signer)
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
        root["servers"] = .array(servers.map(Self.encode))
        if direct.isEmpty == false { root["direct"] = .array(direct.map(JSONValue.string)) }
        if blocked.isEmpty == false { root["blocked"] = .array(blocked.map(JSONValue.string)) }
        return .object(root)
    }

    private static func encode(_ server: MCPServerDefinition) -> JSONValue {
        var object = JSONObject()
        object["name"] = .string(server.name)
        if let description = server.description { object["description"] = .string(description) }
        object["command"] = .string(server.command)
        if server.args.isEmpty == false { object["args"] = .array(server.args.map(JSONValue.string)) }
        if server.environment.isEmpty == false { object["env"] = stringMap(server.environment) }
        if server.secrets.isEmpty == false { object["secrets"] = stringMap(server.secrets) }
        var tools = JSONObject()
        if let decision = server.tools.defaultDecision { tools["default"] = .string(decision.rawValue) }
        if server.tools.allow.isEmpty == false { tools["allow"] = .array(server.tools.allow.map(JSONValue.string)) }
        if server.tools.ask.isEmpty == false { tools["ask"] = .array(server.tools.ask.map(JSONValue.string)) }
        if server.tools.deny.isEmpty == false { tools["deny"] = .array(server.tools.deny.map(JSONValue.string)) }
        if tools.isEmpty == false { object["tools"] = .object(tools) }
        if let sandbox = server.sandbox {
            var value = JSONObject()
            value["network"] = .bool(sandbox.network)
            if sandbox.writable.isEmpty == false { value["writable"] = .array(sandbox.writable.map(JSONValue.string)) }
            object["sandbox"] = .object(value)
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
        try allowOnly(object, ["version", "defaultDecision", "servers", "direct", "blocked"], "top level")
        guard object["version"]?.intValue == 1 else { throw MCPConfigurationError.invalid("version must be 1") }
        var configuration = MCPConfiguration()
        if let raw = object["defaultDecision"] {
            configuration.defaultDecision = try decision(raw, "defaultDecision")
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
        try allowOnly(object, ["name", "description", "command", "args", "env", "secrets", "tools", "sandbox"], context)
        guard let command = object["command"]?.stringValue, command.isEmpty == false, command.contains("\0") == false else {
            throw MCPConfigurationError.invalid("\(context) needs a command")
        }
        var definition = MCPServerDefinition(name: name, command: command)
        if let raw = object["description"] {
            guard let text = raw.stringValue else { throw MCPConfigurationError.invalid("\(context) description must be a string") }
            definition.description = text
        }
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
        if let raw = object["tools"] { definition.tools = try tools(raw, context) }
        if let raw = object["sandbox"] { definition.sandbox = try sandbox(raw, context) }
        return definition
    }

    private static func tools(_ value: JSONValue, _ context: String) throws -> MCPToolPolicy {
        let object = try objectValue(value, "\(context) tools")
        try allowOnly(object, ["default", "allow", "ask", "deny"], "\(context) tools")
        var policy = MCPToolPolicy()
        if let raw = object["default"] { policy.defaultDecision = try decision(raw, "\(context) tools.default") }
        policy.allow = try globs(object["allow"], "\(context) tools.allow")
        policy.ask = try globs(object["ask"], "\(context) tools.ask")
        policy.deny = try globs(object["deny"], "\(context) tools.deny")
        return policy
    }

    private static func sandbox(_ value: JSONValue, _ context: String) throws -> MCPSandboxPolicy {
        let object = try objectValue(value, "\(context) sandbox")
        try allowOnly(object, ["network", "writable"], "\(context) sandbox")
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
        return policy
    }

    private static func decision(_ value: JSONValue, _ context: String) throws -> MCPToolDecision {
        guard let raw = value.stringValue, let decision = MCPToolDecision(rawValue: raw) else {
            throw MCPConfigurationError.invalid("\(context) must be allow, ask or deny")
        }
        return decision
    }

    private static func globs(_ value: JSONValue?, _ context: String) throws -> [String] {
        guard let value else { return [] }
        guard let items = value.stringArray, items.allSatisfy({ $0.isEmpty == false && $0.count <= 256 }) else {
            throw MCPConfigurationError.invalid("\(context) must be non-empty strings")
        }
        return items
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

/// `${secret:NAME}` inside an mcp.json arg: replaced at launch with the rv
/// secret's value, so credentials passed as flags never live in a config file.
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
