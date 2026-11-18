#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

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
    case muse
}

public enum MCPEntryScope: Sendable, Equatable {
    case user
    case project(String)
    /// The organization's system-wide config (Claude Code managed files).
    case managed
    /// A Claude Code plugin, by plugin id (`name@marketplace`).
    case plugin(String)

    public var label: String {
        switch self {
        case .user: "user"
        case .project(let path): "project \(path)"
        case .managed: "managed"
        case .plugin(let id): "plugin \(id)"
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
    /// What the host said about a remote entry's transport; nil when it did not say.
    public var remoteTransport: MCPRemoteTransport?

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

    /// Server name when `command` is absolute and the arguments are exactly
    /// `mcp serve --server NAME` (or `--server=NAME`). Extra arguments,
    /// including a second `--server`, are not a gateway launch.
    public var governedServer: String? {
        guard case .stdio(let command, let args) = transport, command.hasPrefix("/") else { return nil }
        return Self.gatewayServerName(args)
    }

    /// True when this entry's command is the same file as `rvExecutable`.
    /// The installed layout is a shim (`rv`) that execs `rv-cli` next to
    /// it: setup writes the shim path into host configs while the process
    /// answering `rv mcp list` is `rv-cli`, so the sibling shim of an
    /// `rv-cli` executable also counts as a launch of this rv.
    public func launches(_ rvExecutable: String) -> Bool {
        guard case .stdio(let command, _) = transport else { return false }
        if MCPFileIdentity.sameFile(command, rvExecutable) { return true }
        guard (rvExecutable as NSString).lastPathComponent == "rv-cli" else { return false }
        let shim = (rvExecutable as NSString).deletingLastPathComponent + "/rv"
        return MCPFileIdentity.sameFile(command, shim)
    }

    static func gatewayServerName(_ args: [String]) -> String? {
        if args.count == 4, args[0] == "mcp", args[1] == "serve", args[2] == "--server" {
            return serverToken(args[3])
        }
        if args.count == 3, args[0] == "mcp", args[1] == "serve", args[2].hasPrefix("--server=") {
            return serverToken(String(args[2].dropFirst("--server=".count)))
        }
        return nil
    }

    static func serverToken(_ name: String) -> String? {
        guard name.isEmpty == false, name.hasPrefix("-") == false else { return nil }
        return name
    }
}

/// Same-file checks for the rv binary `rv mcp check` is running.
enum MCPFileIdentity {
    static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.hasPrefix("/"), rhs.hasPrefix("/"), let left = realPath(lhs), let right = realPath(rhs) else {
            return false
        }
        return left == right
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Path of the process answering `rv mcp list` / `rv mcp check`.
public enum MCPExecutable {
    public static func currentPath() -> String {
        #if os(Linux)
        if let path = MCPFileIdentity.realPath("/proc/self/exe") { return path }
        #endif
        #if canImport(Darwin)
        var size = UInt32(1024)
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) == 0 { return String(cString: buffer) }
        buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) == 0 { return String(cString: buffer) }
        #endif
        return Bundle.main.executableURL?.path ?? ""
    }
}

/// Where a host keeps MCP servers, and how the servers object is shaped.
public struct MCPHostFile: Sendable, Equatable {
    public enum Format: Sendable, Equatable {
        /// JSON object of servers at `keyPath`; `opencode` uses its own entry shape.
        case json(keyPath: [String], lenient: Bool, opencode: Bool)
        case codexTOML
        /// A plugin servers file: `mcpServers`, or the root object itself.
        case pluginServers(disabled: Bool)
        /// A plugin manifest: inline `mcpServers` (an object, or objects in an array).
        case pluginManifest(disabled: Bool)
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

    /// Host files `rv mcp setup` may route through rv, from the shared
    /// `MCPHostConfigLocation` table the hook guard also reads. Managed and
    /// plugin sources are read-only: `MCPInventory.discover` adds them.
    public static func all(home: URL, project: URL?, environment: [String: String]) -> [MCPHostFile] {
        let homePath = home.path
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true).path }
        let projectPath = project?.standardizedFileURL.path
        var files: [MCPHostFile] = []
        for location in MCPHostConfigLocation.allCases {
            guard let format = setupFormat(location), let host = MCPHost(rawValue: location.host),
                  let path = location.path(home: homePath, codexHome: codexHome, project: projectPath)
            else { continue }
            var scope = MCPEntryScope.user
            if case .project = location.anchor, let projectPath {
                scope = .project(projectPath)
                if location == .claudeCodeProject,
                   let claudeJSON = MCPHostConfigLocation.claudeCodeUser.path(
                       home: homePath, codexHome: codexHome, project: nil)
                {
                    files.append(MCPHostFile(
                        host: .claudeCode, scope: scope, path: URL(fileURLWithPath: claudeJSON, isDirectory: false),
                        format: .json(keyPath: ["projects", projectPath, "mcpServers"], lenient: false, opencode: false)))
                }
            }
            files.append(MCPHostFile(
                host: host, scope: scope, path: URL(fileURLWithPath: path, isDirectory: false), format: format))
        }
        return files
    }

    /// Nil for read-only locations, which `rv mcp setup` never rewrites.
    static func setupFormat(_ location: MCPHostConfigLocation) -> Format? {
        let standard = Format.json(keyPath: ["mcpServers"], lenient: false, opencode: false)
        switch location {
        case .claudeCodeUser, .claudeDesktopUser, .cursorUser, .geminiUser, .antigravityUser, .windsurfUser,
             .museUser, .claudeCodeProject, .cursorProject, .geminiProject:
            return standard
        case .codexUser:
            return .codexTOML
        case .opencodeUser, .opencodeUserJSONC, .opencodeProject:
            return .json(keyPath: ["mcp"], lenient: true, opencode: true)
        case .vscodeUser, .vscodeProject:
            return .json(keyPath: ["servers"], lenient: true, opencode: false)
        case .claudeCodeManagedMCP, .claudeCodeManagedSettings, .claudeCodeManagedSettingsDropIns,
             .claudeCodePlugins:
            return nil
        }
    }
}

public struct MCPInventoryProblem: Error, Sendable, Equatable {
    public var path: String
    public var message: String
}

public struct MCPInventory: Sendable, Equatable {
    public static let maximumFileBytes = 32 * 1024 * 1024

    public enum HostFile: Sendable, Equatable {
        case missing
        case data(Data)
        case unreadable(String)
    }

    public var entries: [MCPHostEntry]
    public var problems: [MCPInventoryProblem]
    /// Host config files that exist (read or not).
    public var filesSeen: [String]

    /// Setup targets (`MCPHostFile.all`) first, then the read-only managed
    /// and plugin sources. `managedDirectory` is Claude Code's system
    /// directory; tests pass a temporary one.
    public static func discover(
        home: URL,
        project: URL?,
        environment: [String: String],
        managedDirectory: String = MCPHostConfigPaths.claudeCodeManagedDirectory,
        read: (URL) -> HostFile = MCPInventory.readFile,
        list: (URL) -> [String] = MCPInventory.listDirectory
    ) -> MCPInventory {
        var inventory = MCPInventory(entries: [], problems: [], filesSeen: [])
        let readOnly = MCPReadOnlySources.files(
            home: home, project: project, environment: environment, managedDirectory: managedDirectory,
            read: read, list: list, problems: &inventory.problems)
        for file in MCPHostFile.all(home: home, project: project, environment: environment) + readOnly {
            switch read(file.path) {
            case .missing:
                continue
            case .unreadable(let message):
                let path = file.path.path
                if inventory.filesSeen.contains(path) == false { inventory.filesSeen.append(path) }
                if inventory.problems.contains(where: { $0.path == path }) == false {
                    inventory.problems.append(MCPInventoryProblem(path: path, message: message))
                }
            case .data(let data):
                if inventory.filesSeen.contains(file.path.path) == false { inventory.filesSeen.append(file.path.path) }
                switch entries(in: data, file: file) {
                case .success(let found): inventory.entries += found
                case .failure(let problem): inventory.problems.append(problem)
                }
            }
        }
        return inventory
    }

    /// Missing files (`ENOENT`) are `.missing`. Anything that exists but cannot
    /// be read, including a directory or a file over `maximumFileBytes`, is
    /// `.unreadable`.
    public static func readFile(_ url: URL) -> HostFile {
        var info = stat()
        if stat(url.path, &info) != 0 {
            return errno == ENOENT ? .missing : .unreadable(readFailure(errno))
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return .unreadable("not a regular file") }
        guard info.st_size >= 0, info.st_size <= Int64(maximumFileBytes) else {
            return .unreadable("larger than \(maximumFileBytes) bytes")
        }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .unreadable(readFailure(errno)) }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var count = 0
        while count < bytes.count {
            let n = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base + count, raw.count - count)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            count += n
        }
        guard count == bytes.count else { return .unreadable("could not be read") }
        return .data(Data(bytes))
    }

    /// Entry names of a directory; empty when it is missing or unreadable.
    public static func listDirectory(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    static func readFailure(_ code: Int32) -> String {
        switch code {
        case EACCES, EPERM: "permission denied"
        default: "could not be read"
        }
    }

    /// Resolve `..`, symlinks, and a trailing slash. A path that is not on
    /// disk falls back to the lexical form, so two missing spellings still compare.
    static func canonicalProjectPath(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        if let resolved = MCPFileIdentity.realPath(trimmed) {
            var text = resolved
            while text.count > 1, text.hasSuffix("/") { text.removeLast() }
            return text
        }
        var lexical = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
        while lexical.count > 1, lexical.hasSuffix("/") { lexical.removeLast() }
        return lexical
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
            if file.host == .claudeCode, case .project(let projectPath) = file.scope, keyPath.first == "projects" {
                return .success(claudeProjectEntries(root: root, projectPath: projectPath, file: file))
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
        case .pluginServers(let disabled), .pluginManifest(let disabled):
            let root: JSONValue
            do {
                root = try JSONValue.parse(data, maximumDepth: 128)
            } catch {
                return problem("could not parse JSON")
            }
            let maps: [JSONObject]
            if case .pluginManifest = file.format {
                switch root["mcpServers"] {
                case .object(let object): maps = [object]
                case .array(let items): maps = items.compactMap(\.objectValue)
                default: maps = []
                }
            } else {
                maps = [root["mcpServers"]?.objectValue ?? root.objectValue].compactMap { $0 }
            }
            return .success(maps.flatMap { servers in
                servers.entries.compactMap { name, value -> MCPHostEntry? in
                    guard let object = value.objectValue,
                          var entry = standardEntry(name: name, object: object, file: file)
                    else { return nil }
                    if disabled { entry.isDisabled = true }
                    return entry
                }
            })
        }
    }

    /// Every `projects` key whose canonical path is the requested project.
    /// Other projects are left unread.
    static func claudeProjectEntries(root: JSONValue, projectPath: String, file: MCPHostFile) -> [MCPHostEntry] {
        guard let projects = root["projects"]?.objectValue else { return [] }
        let wanted = canonicalProjectPath(projectPath)
        var found: [MCPHostEntry] = []
        for (key, value) in projects.entries {
            guard canonicalProjectPath(key) == wanted, let servers = value["mcpServers"]?.objectValue else { continue }
            for (name, server) in servers.entries {
                guard let object = server.objectValue, let entry = standardEntry(name: name, object: object, file: file) else {
                    continue
                }
                found.append(entry)
            }
        }
        return found
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
        var entry = MCPHostEntry(
            host: file.host, scope: file.scope, configPath: file.path.path, name: name, transport: transport,
            environment: stringMap(object["env"]), headers: stringMap(object["headers"]), isDisabled: disabled)
        if case .remote = transport { entry.remoteTransport = remoteTransport(object, host: file.host) }
        return entry
    }

    /// Gemini CLI: `url` is SSE, `httpUrl` streamable HTTP. Others say `"type"`.
    static func remoteTransport(_ object: JSONObject, host: MCPHost) -> MCPRemoteTransport? {
        if object["httpUrl"] != nil { return .http }
        switch object["type"]?.stringValue?.lowercased() {
        case "sse": return .sse
        case "http", "streamable-http", "streamablehttp": return .http
        default: return host == .gemini && object["url"] != nil ? .sse : nil
        }
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

    /// Whether `rv mcp check` accepts this status. Nothing that runs
    /// outside rv passes: a `direct` entry is recorded, not accepted.
    public var isAcceptable: Bool {
        switch self {
        case .governed, .disabled: true
        case .direct, .bypass, .unreviewed, .blocked, .dangling: false
        }
    }

    public var explanation: String {
        switch self {
        case .governed: "runs through rv"
        case .direct: "runs outside rv (mcp.json direct); import it through rv or disable it"
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

    public static func rows(
        _ inventory: MCPInventory, configuration: MCPConfiguration, rvExecutable: String
    ) -> [MCPInventoryRow] {
        inventory.entries.map { row($0, configuration: configuration, rvExecutable: rvExecutable) }
    }

    public static func row(
        _ entry: MCPHostEntry, configuration: MCPConfiguration, rvExecutable: String
    ) -> MCPInventoryRow {
        let display: String
        var credentials: [String] = []
        switch entry.transport {
        case .stdio(let command, let args):
            let masked = MCPRedaction.args(args)
            let shownCommand: String
            if MCPRedaction.looksLikeToken(command) || MCPRedaction.valueCarriesSecret(command) {
                shownCommand = MCPRedaction.mask
                credentials.append("command")
            } else {
                shownCommand = command
            }
            display = ([shownCommand] + masked.shown).joined(separator: " ")
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
            status: status(entry, configuration: configuration, rvExecutable: rvExecutable),
            display: display,
            environmentNames: entry.environment.keys.sorted(),
            headerNames: entry.headers.keys.sorted(),
            plaintextCredentials: credentials)
    }

    /// Governed only when the command is an absolute gateway launch of this
    /// `rvExecutable` (same file) for a server mcp.json defines.
    public static func status(
        _ entry: MCPHostEntry, configuration: MCPConfiguration, rvExecutable: String
    ) -> MCPEntryStatus {
        if let server = entry.governedServer, entry.launches(rvExecutable) {
            if configuration.isBlocked(server) { return .blocked }
            return configuration.server(named: server) == nil ? .dangling : .governed
        }
        if configuration.isBlocked(entry.name) { return .blocked }
        if entry.isDisabled { return .disabled }
        if configuration.isDirect(entry.name) { return .direct }
        if configuration.server(named: entry.name) != nil { return .bypass }
        return .unreviewed
    }
}
