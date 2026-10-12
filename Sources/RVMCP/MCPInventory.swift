import Foundation

public enum MCPHost: String, CaseIterable, Sendable, Equatable {
    case claudeCode = "claude-code"
    case claudeDesktop = "claude-desktop"
    case cursor
    case codex
    case opencode
    case gemini
    case antigravity
    case vscode
    case windsurf
}

public enum MCPEntryScope: Sendable, Equatable {
    case user
    case project(String)

    public var label: String {
        switch self {
        case .user: "user"
        case .project(let path): "project \(path)"
        }
    }
}

public enum MCPTransport: Sendable, Equatable {
    case stdio(command: String, args: [String])
    case remote(url: String)
}

/// One MCP server as a host has it configured. `environment` and `headers`
/// hold raw values for `rv mcp import`; never display them.
public struct MCPHostEntry: Sendable, Equatable {
    public var host: MCPHost
    public var scope: MCPEntryScope
    public var configPath: String
    public var name: String
    public var transport: MCPTransport
    public var environment: [String: String]
    public var headers: [String: String]
    public var isDisabled: Bool

    public init(
        host: MCPHost,
        scope: MCPEntryScope,
        configPath: String,
        name: String,
        transport: MCPTransport,
        environment: [String: String] = [:],
        headers: [String: String] = [:],
        isDisabled: Bool = false
    ) {
        self.host = host
        self.scope = scope
        self.configPath = configPath
        self.name = name
        self.transport = transport
        self.environment = environment
        self.headers = headers
        self.isDisabled = isDisabled
    }

    /// The rv server this entry routes through, when it runs `rv mcp serve --server NAME`.
    public var governedServer: String? {
        guard case .stdio(let command, let args) = transport,
            (command as NSString).lastPathComponent == "rv",
            args.count >= 2, args[0] == "mcp", args[1] == "serve"
        else { return nil }
        for (index, arg) in args.enumerated() {
            if arg == "--server", index + 1 < args.count { return args[index + 1] }
            if arg.hasPrefix("--server=") { return String(arg.dropFirst("--server=".count)) }
        }
        return nil
    }
}

/// Where a host keeps MCP servers, and how the servers object is shaped.
public struct MCPHostFile: Sendable, Equatable {
    public enum Format: Sendable, Equatable {
        /// JSON object of servers at `keyPath`; `opencode` uses its own entry shape.
        case json(keyPath: [String], lenient: Bool, opencode: Bool)
        case codexTOML
    }

    public var host: MCPHost
    public var scope: MCPEntryScope
    public var path: URL
    public var format: Format

    public init(host: MCPHost, scope: MCPEntryScope, path: URL, format: Format) {
        self.host = host
        self.scope = scope
        self.path = path
        self.format = format
    }

    public static func all(home: URL, project: URL?, environment: [String: String]) -> [MCPHostFile] {
        func at(_ base: URL, _ relative: String) -> URL { base.appendingPathComponent(relative, isDirectory: false) }
        let standard = Format.json(keyPath: ["mcpServers"], lenient: false, opencode: false)
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? at(home, ".codex")
        #if os(macOS)
        let claudeDesktop = at(home, "Library/Application Support/Claude/claude_desktop_config.json")
        let vscodeUser = at(home, "Library/Application Support/Code/User/mcp.json")
        #else
        let claudeDesktop = at(home, ".config/Claude/claude_desktop_config.json")
        let vscodeUser = at(home, ".config/Code/User/mcp.json")
        #endif
        var files = [
            MCPHostFile(host: .claudeCode, scope: .user, path: at(home, ".claude.json"), format: standard),
            MCPHostFile(host: .claudeDesktop, scope: .user, path: claudeDesktop, format: standard),
            MCPHostFile(host: .cursor, scope: .user, path: at(home, ".cursor/mcp.json"), format: standard),
            MCPHostFile(host: .codex, scope: .user, path: at(codexHome, "config.toml"), format: .codexTOML),
            MCPHostFile(
                host: .opencode, scope: .user, path: at(home, ".config/opencode/opencode.json"),
                format: .json(keyPath: ["mcp"], lenient: true, opencode: true)),
            MCPHostFile(
                host: .opencode, scope: .user, path: at(home, ".config/opencode/opencode.jsonc"),
                format: .json(keyPath: ["mcp"], lenient: true, opencode: true)),
            MCPHostFile(host: .gemini, scope: .user, path: at(home, ".gemini/settings.json"), format: standard),
            MCPHostFile(
                host: .antigravity, scope: .user, path: at(home, ".gemini/antigravity/mcp_config.json"), format: standard),
            MCPHostFile(
                host: .vscode, scope: .user, path: vscodeUser,
                format: .json(keyPath: ["servers"], lenient: true, opencode: false)),
            MCPHostFile(host: .windsurf, scope: .user, path: at(home, ".codeium/windsurf/mcp_config.json"), format: standard),
        ]
        guard let project else { return files }
        let projectPath = project.standardizedFileURL.path
        let scope = MCPEntryScope.project(projectPath)
        files += [
            MCPHostFile(
                host: .claudeCode, scope: scope, path: at(home, ".claude.json"),
                format: .json(keyPath: ["projects", projectPath, "mcpServers"], lenient: false, opencode: false)),
            MCPHostFile(host: .claudeCode, scope: scope, path: at(project, ".mcp.json"), format: standard),
            MCPHostFile(host: .cursor, scope: scope, path: at(project, ".cursor/mcp.json"), format: standard),
            MCPHostFile(
                host: .vscode, scope: scope, path: at(project, ".vscode/mcp.json"),
                format: .json(keyPath: ["servers"], lenient: true, opencode: false)),
            MCPHostFile(
                host: .opencode, scope: scope, path: at(project, "opencode.json"),
                format: .json(keyPath: ["mcp"], lenient: true, opencode: true)),
            MCPHostFile(host: .gemini, scope: scope, path: at(project, ".gemini/settings.json"), format: standard),
        ]
        return files
    }
}

public struct MCPInventoryProblem: Error, Sendable, Equatable {
    public var path: String
    public var message: String
}

public struct MCPInventory: Sendable, Equatable {
    public static let maximumFileBytes = 32 * 1024 * 1024

    public var entries: [MCPHostEntry]
    public var problems: [MCPInventoryProblem]
    /// Host config files that exist (read or not).
    public var filesSeen: [String]

    public static func discover(
        home: URL,
        project: URL?,
        environment: [String: String],
        read: (URL) -> Data? = MCPInventory.readFile
    ) -> MCPInventory {
        var inventory = MCPInventory(entries: [], problems: [], filesSeen: [])
        for file in MCPHostFile.all(home: home, project: project, environment: environment) {
            guard let data = read(file.path) else { continue }
            if inventory.filesSeen.contains(file.path.path) == false { inventory.filesSeen.append(file.path.path) }
            switch entries(in: data, file: file) {
            case .success(let found): inventory.entries += found
            case .failure(let problem): inventory.problems.append(problem)
            }
        }
        return inventory
    }

    public static func readFile(_ url: URL) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? Int, size <= maximumFileBytes
        else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func entries(in data: Data, file: MCPHostFile) -> Result<[MCPHostEntry], MCPInventoryProblem> {
        func problem(_ message: String) -> Result<[MCPHostEntry], MCPInventoryProblem> {
            .failure(MCPInventoryProblem(path: file.path.path, message: message))
        }
        switch file.format {
        case .codexTOML:
            let root: [String: TOMLValue]
            do {
                root = try MiniTOML.parse(String(decoding: data, as: UTF8.self))
            } catch {
                return problem("could not parse TOML (line \(error.line))")
            }
            guard let servers = root["mcp_servers"]?.tableValue else { return .success([]) }
            return .success(servers.keys.sorted().compactMap { name in
                servers[name]?.tableValue.flatMap { codexEntry(name: name, table: $0, file: file) }
            })
        case .json(let keyPath, let lenient, let opencode):
            let root: JSONValue
            do {
                root = try JSONValue.parse(data, maximumDepth: 128, lenient: lenient)
            } catch {
                return problem("could not parse JSON")
            }
            var node: JSONValue? = root
            for key in keyPath { node = node?[key] }
            guard let servers = node?.objectValue else { return .success([]) }
            return .success(servers.entries.compactMap { name, value in
                guard let object = value.objectValue else { return nil }
                return opencode
                    ? opencodeEntry(name: name, object: object, file: file)
                    : standardEntry(name: name, object: object, file: file)
            })
        }
    }

    static func standardEntry(name: String, object: JSONObject, file: MCPHostFile) -> MCPHostEntry? {
        let transport: MCPTransport
        if let command = object["command"]?.stringValue {
            transport = .stdio(command: command, args: object["args"]?.stringArray ?? [])
        } else if let url = object["url"]?.stringValue ?? object["httpUrl"]?.stringValue
            ?? object["serverUrl"]?.stringValue
        {
            transport = .remote(url: url)
        } else {
            return nil
        }
        let disabled = object["disabled"]?.boolValue == true || object["enabled"]?.boolValue == false
        return MCPHostEntry(
            host: file.host, scope: file.scope, configPath: file.path.path, name: name, transport: transport,
            environment: stringMap(object["env"]), headers: stringMap(object["headers"]), isDisabled: disabled)
    }

    static func opencodeEntry(name: String, object: JSONObject, file: MCPHostFile) -> MCPHostEntry? {
        let transport: MCPTransport
        if let command = object["command"]?.stringArray, let executable = command.first {
            transport = .stdio(command: executable, args: Array(command.dropFirst()))
        } else if let url = object["url"]?.stringValue {
            transport = .remote(url: url)
        } else {
            return nil
        }
        return MCPHostEntry(
            host: file.host, scope: file.scope, configPath: file.path.path, name: name, transport: transport,
            environment: stringMap(object["environment"]), headers: stringMap(object["headers"]),
            isDisabled: object["enabled"]?.boolValue == false)
    }

    static func codexEntry(name: String, table: [String: TOMLValue], file: MCPHostFile) -> MCPHostEntry? {
        let transport: MCPTransport
        if let command = table["command"]?.stringValue {
            transport = .stdio(command: command, args: table["args"]?.stringArray ?? [])
        } else if let url = table["url"]?.stringValue {
            transport = .remote(url: url)
        } else {
            return nil
        }
        func strings(_ value: TOMLValue?) -> [String: String] {
            (value?.tableValue ?? [:]).compactMapValues(\.stringValue)
        }
        return MCPHostEntry(
            host: file.host, scope: file.scope, configPath: file.path.path, name: name, transport: transport,
            environment: strings(table["env"]), headers: strings(table["http_headers"]),
            isDisabled: table["enabled"]?.boolValue == false)
    }

    static func stringMap(_ value: JSONValue?) -> [String: String] {
        var map: [String: String] = [:]
        for (key, raw) in value?.objectValue?.entries ?? [] {
            if let text = raw.stringValue { map[key] = text }
        }
        return map
    }
}

public enum MCPEntryStatus: String, Sendable, Equatable {
    case governed
    case direct
    case bypass
    case unreviewed
    case blocked
    case dangling
    case disabled

    /// Whether `rv mcp check` accepts this status.
    public var isAcceptable: Bool {
        switch self {
        case .governed, .direct, .disabled: true
        case .bypass, .unreviewed, .blocked, .dangling: false
        }
    }

    public var explanation: String {
        switch self {
        case .governed: "runs through rv"
        case .direct: "allowed to run outside rv (mcp.json direct)"
        case .bypass: "rv has a definition, but this host runs it directly; run `rv mcp setup`"
        case .unreviewed: "not reviewed; `rv mcp import` it, add it to direct, or block it"
        case .blocked: "blocked by mcp.json"
        case .dangling: "routes through rv, but mcp.json has no such server"
        case .disabled: "disabled in the host"
        }
    }
}

public struct MCPInventoryRow: Sendable, Equatable {
    public var entry: MCPHostEntry
    public var status: MCPEntryStatus
    /// Redacted command line or URL.
    public var display: String
    public var environmentNames: [String]
    public var headerNames: [String]
    /// Names (env vars, headers, flags, arg positions) that hold literal credentials.
    public var plaintextCredentials: [String]

    public static func rows(_ inventory: MCPInventory, configuration: MCPConfiguration) -> [MCPInventoryRow] {
        inventory.entries.map { row($0, configuration: configuration) }
    }

    public static func row(_ entry: MCPHostEntry, configuration: MCPConfiguration) -> MCPInventoryRow {
        let display: String
        var credentials: [String] = []
        switch entry.transport {
        case .stdio(let command, let args):
            let masked = MCPRedaction.args(args)
            display = ([command] + masked.shown).joined(separator: " ")
            credentials += masked.credentials
        case .remote(let url):
            let shown = MCPRedaction.url(url)
            display = shown.display
            if shown.leaked { credentials.append("URL") }
        }
        credentials += MCPRedaction.literalCredentials(entry.environment)
        credentials += MCPRedaction.literalCredentials(entry.headers).map { "header \($0)" }
        return MCPInventoryRow(
            entry: entry,
            status: status(entry, configuration: configuration),
            display: display,
            environmentNames: entry.environment.keys.sorted(),
            headerNames: entry.headers.keys.sorted(),
            plaintextCredentials: credentials)
    }

    public static func status(_ entry: MCPHostEntry, configuration: MCPConfiguration) -> MCPEntryStatus {
        if let server = entry.governedServer {
            if configuration.blocked.contains(server) { return .blocked }
            return configuration.server(named: server) == nil ? .dangling : .governed
        }
        if configuration.blocked.contains(entry.name) { return .blocked }
        if entry.isDisabled { return .disabled }
        if configuration.direct.contains(entry.name) { return .direct }
        if configuration.server(named: entry.name) != nil { return .bypass }
        return .unreviewed
    }
}
