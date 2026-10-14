#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIsolation

/// `rv mcp import`: host entries → mcp.json definitions. Literal credentials
/// (secret-looking env values and flag values) become rv secrets stored in
/// the Keychain and are referenced, never copied into mcp.json.
public struct MCPImportPlan: Sendable {
    public struct NewSecret: Sendable {
        public var definition: SecretDefinition
        public var value: String
    }

    public var servers: [MCPServerDefinition] = []
    public var secrets: [NewSecret] = []
    public var notes: [String] = []
    public var skipped: [(name: String, reason: String)] = []
}

public enum MCPImport {
    public static func plan(
        entries: [MCPHostEntry],
        configuration: MCPConfiguration,
        secrets: SecretsConfiguration,
        allowTools: Bool
    ) -> MCPImportPlan {
        var plan = MCPImportPlan()
        var takenSecrets = Set(secrets.secrets.map(\.name))
        var takenServers = Set(configuration.servers.map(\.name))
        func secretName(_ preferred: String, server: String) -> String {
            var candidates = [sanitize(preferred), sanitize("\(server)_\(preferred)")]
            candidates += (2...99).map { sanitize("\(server)_\(preferred)_\($0)") }
            let name = candidates.first { takenSecrets.contains($0) == false } ?? sanitize("\(server)_\(UUID().uuidString)")
            takenSecrets.insert(name)
            return name
        }
        for entry in entries {
            if entry.governedServer != nil {
                plan.skipped.append((entry.name, "already routed through rv"))
                continue
            }
            guard MCPConfigurationDecoding.isServerName(entry.name) else {
                plan.skipped.append((entry.name, "name is not a valid rv server name"))
                continue
            }
            guard takenServers.contains(entry.name) == false else {
                plan.skipped.append((entry.name, "mcp.json already defines it"))
                continue
            }
            let description = "imported from \(entry.host.rawValue) (\(entry.configPath))"
            guard case .stdio(let command, let args) = entry.transport else {
                guard case .remote(let raw) = entry.transport else { continue }
                switch remoteServer(entry, url: raw, plan: &plan, secretName: secretName) {
                case .failure(let skip): plan.skipped.append((entry.name, skip.reason))
                case .success(let remote):
                    var definition = MCPServerDefinition(name: entry.name, description: description, remote: remote)
                    if allowTools { definition.tools.defaultDecision = .allow }
                    plan.servers.append(definition)
                    takenServers.insert(entry.name)
                }
                continue
            }
            if MCPRedaction.argumentCarriesRefusedSecret(command) {
                plan.skipped.append((entry.name, "the command carries a secret in its URL or path"))
                continue
            }
            if args.contains(where: MCPRedaction.argumentCarriesRefusedSecret) {
                plan.skipped.append((entry.name, "an argument carries a secret in its URL or path"))
                continue
            }
            if entry.environment.values.contains(where: MCPRedaction.credentialHidesAnotherSecret) {
                plan.skipped.append((entry.name, "an environment value carries a second secret"))
                continue
            }
            var definition = MCPServerDefinition(name: entry.name, description: description, command: command)
            if allowTools { definition.tools.defaultDecision = .allow }
            let credentials = Set(MCPRedaction.literalCredentials(entry.environment))
            for (variable, value) in entry.environment.sorted(by: { $0.key < $1.key }) {
                guard SecretsConfiguration.isVariableName(variable) else {
                    plan.notes.append("\(entry.name): dropped env \(variable) (not a variable name)")
                    continue
                }
                if MCPRedaction.isReference(value) {
                    plan.notes.append(
                        "\(entry.name): \(variable) referenced \(value) in the host; rv passes its own environment through, so set \(variable) there")
                } else if credentials.contains(variable) {
                    let name = secretName(variable, server: entry.name)
                    plan.secrets.append(.init(definition: secretDefinition(name, entry), value: value))
                    definition.secrets[variable] = name
                } else {
                    definition.environment[variable] = value
                }
            }
            definition.args = templatedArgs(args, entry: entry, plan: &plan, secretName: secretName)
            plan.servers.append(definition)
            takenServers.insert(entry.name)
        }
        return plan
    }

    struct Skip: Error { var reason: String }

    /// Credential header values become `${secret:NAME}` (an auth scheme such
    /// as `Bearer ` stays literal); headers that point at host variables or
    /// that rv's transport owns are dropped with a note.
    static func remoteServer(
        _ entry: MCPHostEntry, url raw: String, plan: inout MCPImportPlan, secretName: (String, String) -> String
    ) -> Result<MCPRemoteServer, Skip> {
        guard let url = URL(string: raw) else { return .failure(Skip(reason: "url does not parse")) }
        if let problem = MCPRemoteServer.endpointProblem(url) { return .failure(Skip(reason: "url \(problem)")) }
        if MCPRedaction.url(raw).leaked {
            return .failure(Skip(reason: "the URL carries a credential; move it into a header, then import"))
        }
        guard entry.headers.count <= MCPRemoteServer.maximumHeaders else {
            return .failure(Skip(reason: "more than \(MCPRemoteServer.maximumHeaders) headers"))
        }
        for value in entry.headers.values where MCPRedaction.credentialHidesAnotherSecret(headerCredential(value)) {
            return .failure(Skip(reason: "a header value carries a second secret"))
        }
        var remote = MCPRemoteServer(url: url, transport: entry.remoteTransport ?? .http)
        for (header, value) in entry.headers.sorted(by: { $0.key < $1.key }) {
            if MCPConfigurationDecoding.isHeaderName(header) == false
                || MCPRemoteServer.managedHeaders.contains(header.lowercased())
                || value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" })
                || value.contains("${secret:")
            {
                plan.notes.append("\(entry.name): dropped header \(header) (rv sets it, or rv cannot carry its value)")
                continue
            }
            if MCPRedaction.isReference(value) {
                plan.notes.append(
                    "\(entry.name): header \(header) referenced \(value) in the host; store it with `rv secrets set` and use ${secret:NAME}")
                continue
            }
            var scheme = ""
            var credential = value
            if let space = value.firstIndex(of: " "), value[..<space].allSatisfy(\.isLetter) {
                scheme = String(value[...space])
                credential = value[value.index(after: space)...].trimmingCharacters(in: .whitespaces)
            }
            guard credential.isEmpty == false, MCPRedaction.isSecretName(header) || MCPRedaction.looksLikeToken(credential) else {
                remote.headers[header] = value
                continue
            }
            let name = secretName("\(entry.name)_\(header)", entry.name)
            plan.secrets.append(.init(definition: secretDefinition(name, entry), value: credential))
            remote.headers[header] = scheme + "${secret:\(name)}"
        }
        return .success(remote)
    }

    /// `Bearer <token>` keeps the scheme in the stored header and checks the token.
    private static func headerCredential(_ value: String) -> String {
        guard let space = value.firstIndex(of: " "), value[..<space].allSatisfy(\.isLetter) else { return value }
        return value[value.index(after: space)...].trimmingCharacters(in: .whitespaces)
    }

    /// Credential flag values and bare tokens become `${secret:NAME}`.
    static func templatedArgs(
        _ args: [String], entry: MCPHostEntry, plan: inout MCPImportPlan, secretName: (String, String) -> String
    ) -> [String] {
        var output: [String] = []
        var pendingFlag: String?
        for (index, arg) in args.enumerated() {
            if let flag = pendingFlag, arg.hasPrefix("-") == false {
                let name = secretName("\(entry.name)_\(flagWord(flag))", entry.name)
                plan.secrets.append(.init(definition: secretDefinition(name, entry), value: arg))
                output.append("${secret:\(name)}")
                pendingFlag = nil
                continue
            }
            pendingFlag = nil
            if arg.hasPrefix("-") {
                let body = arg.drop { $0 == "-" }
                if let equals = body.firstIndex(of: "=") {
                    let flag = String(body[..<equals])
                    let value = String(body[body.index(after: equals)...])
                    if (MCPRedaction.isSecretName(flag) || MCPRedaction.looksLikeToken(value)), value.isEmpty == false {
                        let name = secretName("\(entry.name)_\(flagWord(flag))", entry.name)
                        plan.secrets.append(.init(definition: secretDefinition(name, entry), value: value))
                        output.append(String(arg[arg.startIndex..<equals]) + "=${secret:\(name)}")
                        continue
                    }
                } else if MCPRedaction.isSecretName(String(body)) {
                    pendingFlag = arg
                }
                output.append(arg)
            } else if arg.contains("://"), MCPRedaction.url(arg).leaked {
                let name = secretName("\(entry.name)_ARG_\(index + 1)", entry.name)
                plan.secrets.append(.init(definition: secretDefinition(name, entry), value: arg))
                output.append("${secret:\(name)}")
            } else if MCPRedaction.looksLikeToken(arg) {
                let name = secretName("\(entry.name)_ARG_\(index + 1)", entry.name)
                plan.secrets.append(.init(definition: secretDefinition(name, entry), value: arg))
                output.append("${secret:\(name)}")
            } else {
                output.append(arg)
            }
        }
        return output
    }

    static func flagWord(_ flag: String) -> String {
        String(flag.drop { $0 == "-" })
    }

    static func secretDefinition(_ name: String, _ entry: MCPHostEntry) -> SecretDefinition {
        SecretDefinition(
            name: name, description: "MCP \(entry.name) credential imported from \(entry.host.rawValue)",
            source: .keychain(service: SecretKeychain.service, account: name), delivery: .environment)
    }

    /// Uppercase variable-name form: `context7 api-key` → `CONTEXT7_API_KEY`.
    static func sanitize(_ raw: String) -> String {
        var name = String(raw.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
        while name.contains("__") { name = name.replacingOccurrences(of: "__", with: "_") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if name.first?.isNumber != false { name = "MCP_" + name }
        return String(name.prefix(64))
    }
}

/// One host entry `rv mcp setup` rewrote, kept so `--undo` can put it back.
public struct MCPSetupRecord: Sendable, Equatable {
    public var host: String
    public var configPath: String
    public var keyPath: [String]
    public var name: String
    public var original: JSONValue
    public var written: JSONValue
}

public struct MCPSetupResult: Sendable, Equatable {
    public var changed: [String] = []
    public var skipped: [String] = []
    public var manualSteps: [String] = []
}

public enum MCPSetupError: Error, Sendable, Equatable {
    case unreadable(String)
    case hasComments(String)
    case writeFailed(String)
    case manifest(String)

    public var message: String {
        switch self {
        case .unreadable(let path): "could not read \(path)"
        case .hasComments(let path): "\(path) has comments or trailing commas rv would lose; edit it by hand"
        case .writeFailed(let path): "could not write \(path)"
        case .manifest(let reason): "setup manifest: \(reason)"
        }
    }
}

/// `rv mcp setup` / `--undo`: point host entries at `rv mcp serve --server NAME`.
public enum MCPHostSetup {
    public static let manifestName = "mcp-setup.json"

    public static func gatewayEntry(rvPath: String, server: String, original: JSONObject, opencode: Bool) -> JSONValue {
        var entry = JSONObject()
        if opencode {
            entry["type"] = .string("local")
            entry["command"] = .array([rvPath, "mcp", "serve", "--server", server].map(JSONValue.string))
            entry["enabled"] = .bool(true)
            return .object(entry)
        }
        if original["type"] != nil { entry["type"] = .string("stdio") }
        entry["command"] = .string(rvPath)
        entry["args"] = .array(["mcp", "serve", "--server", server].map(JSONValue.string))
        return .object(entry)
    }

    public static func setup(
        files: [MCPHostFile],
        configuration: MCPConfiguration,
        servers filter: Set<String>?,
        rvPath: String,
        configDirectory: URL,
        read: (URL) -> MCPInventory.HostFile = MCPInventory.readFile
    ) -> Result<MCPSetupResult, MCPSetupError> {
        var result = MCPSetupResult()
        var records = loadManifest(configDirectory)
        for file in files {
            guard case .data(let data) = read(file.path) else { continue }
            switch file.format {
            case .codexTOML:
                let entries = (try? MCPInventory.entries(in: data, file: file).get()) ?? []
                for entry in entries where wanted(entry.name, filter) && entry.governedServer == nil
                    && configuration.server(named: entry.name) != nil
                {
                    let name = shellQuote(entry.name)
                    let rv = shellQuote(rvPath)
                    result.manualSteps.append(
                        "codex mcp remove \(name) && codex mcp add \(name) -- \(rv) mcp serve --server \(name)")
                }
            case .json(let keyPath, _, let opencode):
                guard let root = try? JSONValue.parse(data, maximumDepth: 128, lenient: true) else {
                    return .failure(.unreadable(file.path.path))
                }
                guard var servers = value(at: keyPath, in: root)?.objectValue else { continue }
                var changed = false
                for (name, entry) in servers.entries where wanted(name, filter) {
                    guard let object = entry.objectValue,
                        let hostEntry = opencode
                            ? MCPInventory.opencodeEntry(name: name, object: object, file: file)
                            : MCPInventory.standardEntry(name: name, object: object, file: file)
                    else { continue }
                    guard hostEntry.governedServer == nil else {
                        result.skipped.append("\(name) (\(file.host.rawValue)): already routed through rv")
                        continue
                    }
                    guard configuration.server(named: name) != nil else {
                        result.skipped.append("\(name) (\(file.host.rawValue)): not in mcp.json; `rv mcp import` it first")
                        continue
                    }
                    let written = gatewayEntry(rvPath: rvPath, server: name, original: object, opencode: opencode)
                    servers[name] = written
                    records.append(MCPSetupRecord(
                        host: file.host.rawValue, configPath: file.path.path, keyPath: keyPath, name: name,
                        original: entry, written: written))
                    result.changed.append("\(name) (\(file.host.rawValue), \(file.path.path))")
                    changed = true
                }
                guard changed else { continue }
                guard (try? JSONValue.parse(data, maximumDepth: 128)) != nil else {
                    return .failure(.hasComments(file.path.path))
                }
                guard let updated = replacing(keyPath, in: root, with: .object(servers)) else {
                    return .failure(.writeFailed(file.path.path))
                }
                guard saveManifest(records, configDirectory) else { return .failure(.manifest("could not save")) }
                guard writePreservingMode(Data(updated.prettyText.utf8), to: file.path) else {
                    return .failure(.writeFailed(file.path.path))
                }
            }
        }
        return .success(result)
    }

    public static func undo(
        host: MCPHost?,
        servers filter: Set<String>?,
        configDirectory: URL,
        read: (URL) -> MCPInventory.HostFile = MCPInventory.readFile
    ) -> Result<MCPSetupResult, MCPSetupError> {
        var result = MCPSetupResult()
        var records = loadManifest(configDirectory)
        let selected = records.indices.filter { index in
            (host == nil || records[index].host == host?.rawValue) && wanted(records[index].name, filter)
        }
        var done = Set<Int>()
        for path in Set(selected.map { records[$0].configPath }).sorted() {
            let url = URL(fileURLWithPath: path)
            let mine = selected.filter { records[$0].configPath == path }
            guard case .data(let data) = read(url), var root = try? JSONValue.parse(data, maximumDepth: 128) else {
                result.skipped += mine.map { "\(records[$0].name): \(path) is missing or unreadable" }
                done.formUnion(mine)
                continue
            }
            var changed = false
            for index in mine.reversed() {
                let record = records[index]
                done.insert(index)
                guard var servers = value(at: record.keyPath, in: root)?.objectValue,
                    servers[record.name] == record.written
                else {
                    result.skipped.append("\(record.name) (\(record.host)): changed since setup; left as is")
                    continue
                }
                servers[record.name] = record.original
                guard let updated = replacing(record.keyPath, in: root, with: .object(servers)) else { continue }
                root = updated
                changed = true
                result.changed.append("\(record.name) (\(record.host), \(path))")
            }
            if changed, writePreservingMode(Data(root.prettyText.utf8), to: url) == false {
                return .failure(.writeFailed(path))
            }
        }
        records = records.indices.filter { done.contains($0) == false }.map { records[$0] }
        guard saveManifest(records, configDirectory) else { return .failure(.manifest("could not save")) }
        return .success(result)
    }

    /// Single quotes, with an embedded `'` written as `'\''`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func wanted(_ name: String, _ filter: Set<String>?) -> Bool {
        filter.map { $0.contains(name) } ?? true
    }

    static func value(at path: [String], in root: JSONValue) -> JSONValue? {
        var node: JSONValue? = root
        for key in path { node = node?[key] }
        return node
    }

    static func replacing(_ path: [String], in root: JSONValue, with value: JSONValue) -> JSONValue? {
        guard let key = path.first else { return value }
        guard var object = root.objectValue, let child = object[key] else { return nil }
        guard let replaced = replacing(Array(path.dropFirst()), in: child, with: value) else { return nil }
        object[key] = replaced
        return .object(object)
    }

    /// Temp file + rename in the same directory, keeping the original mode.
    static func writePreservingMode(_ data: Data, to url: URL) -> Bool {
        var info = stat()
        let mode = lstat(url.path, &info) == 0 ? info.st_mode & 0o777 : 0o600
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).rv-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: mode]),
            rename(temporary.path, url.path) == 0
        else {
            unlink(temporary.path)
            return false
        }
        return true
    }

    static func manifestURL(_ configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent(manifestName)
    }

    static func loadManifest(_ configDirectory: URL) -> [MCPSetupRecord] {
        guard case .success(let data?) = OwnerOnlyFile.read(manifestURL(configDirectory), maximumBytes: 8 * 1024 * 1024),
            let root = try? JSONValue.parse(data, maximumDepth: 160),
            let items = root["records"]?.arrayValue
        else { return [] }
        return items.compactMap { item in
            guard let host = item["host"]?.stringValue, let path = item["configPath"]?.stringValue,
                let keyPath = item["keyPath"]?.stringArray, let name = item["name"]?.stringValue,
                let original = item["original"], let written = item["written"]
            else { return nil }
            return MCPSetupRecord(host: host, configPath: path, keyPath: keyPath, name: name, original: original, written: written)
        }
    }

    static func saveManifest(_ records: [MCPSetupRecord], _ configDirectory: URL) -> Bool {
        let root = JSONValue.object([
            "version": .int(1),
            "records": .array(records.map { record in
                .object([
                    "host": .string(record.host), "configPath": .string(record.configPath),
                    "keyPath": .array(record.keyPath.map(JSONValue.string)), "name": .string(record.name),
                    "original": record.original, "written": record.written,
                ])
            }),
        ])
        return OwnerOnlyFile.write(Data(root.prettyText.utf8), to: manifestURL(configDirectory))
    }
}
