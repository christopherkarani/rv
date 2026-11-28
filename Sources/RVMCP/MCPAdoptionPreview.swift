import Foundation

/// One host entry rv rewrites, as the person sees it before saying yes:
/// the entry before and after, each one line of JSON with every
/// environment and header value masked and credential-like arguments and
/// URLs redacted. No secret value is ever in this text.
public struct MCPRouteChange: Sendable, Equatable {
    public var host: MCPHost
    public var path: String
    public var name: String
    public var before: String
    public var after: String
}

/// Every rewrite a plan makes, before anything is written.
public struct MCPRoutePreview: Sendable, Equatable {
    public var changes: [MCPRouteChange] = []
    /// Codex keeps servers in TOML, which rv does not rewrite: the command
    /// the person runs instead, one per server.
    public var manualSteps: [String] = []
    /// Files rv writes back in its own two-space layout (their bytes were
    /// laid out another way), so a `diff` of the backup shows more lines.
    public var relaid: [String] = []

    public var paths: [String] {
        var seen = Set<String>()
        return changes.map(\.path).filter { seen.insert($0).inserted }
    }
}

extension MCPAdoption {
    /// The host rewrites `survey` makes once its imports are in mcp.json.
    /// The same planner `rv mcp setup` writes with, run on the bytes `read`
    /// returns; nothing is written.
    public static func routePreview(
        _ survey: MCPAdoptionSurvey,
        files: [MCPHostFile],
        configuration: MCPConfiguration,
        rvPath: String,
        read: (URL) -> MCPInventory.HostFile = MCPInventory.readFile
    ) -> Result<MCPRoutePreview, MCPSetupError> {
        var after = configuration
        after.servers += survey.imports.servers
        var preview = MCPRoutePreview()
        for host in MCPHost.allCases {
            guard let names = survey.routes[host], names.isEmpty == false else { continue }
            let snapshots = files.filter { $0.host == host }.map { file in
                MCPHostSnapshot(
                    file: file,
                    state: MCPFileState(contents: read(file.path), isSymbolicLink: MCPHostSetup.isSymbolicLink(file.path)))
            }
            let plan: MCPSetupPlan
            switch MCPHostSetup.plan(
                snapshots: snapshots, manifest: [], configuration: after, servers: names, rvPath: rvPath)
            {
            case .failure(let error): return .failure(error)
            case .success(let planned): plan = planned
            }
            preview.manualSteps += plan.report.manualSteps
            for write in plan.writes {
                for record in write.records {
                    preview.changes.append(MCPRouteChange(
                        host: host, path: write.path.path, name: record.name,
                        before: shownEntry(record.name, record.original), after: rvEntry(record.name, record.written)))
                }
                if case .data(let bytes) = read(write.path), let parsed = try? JSONValue.parse(bytes, maximumDepth: 128),
                    Data(parsed.prettyText.utf8) != bytes
                {
                    preview.relaid.append(write.path.path)
                }
            }
        }
        return .success(preview)
    }

    /// What `rv mcp remove` puts back: each entry rv wrote that is still as
    /// rv wrote it, from the setup manifest `records`. Entries changed
    /// since are left alone by undo, and are not listed here.
    public static func undoPreview(
        records: [MCPSetupRecord], host: MCPHost?,
        read: (URL) -> MCPInventory.HostFile = MCPInventory.readFile
    ) -> [MCPRouteChange] {
        var roots: [String: JSONValue?] = [:]
        var changes: [MCPRouteChange] = []
        for record in records where host == nil || record.host == host?.rawValue {
            guard let recordHost = MCPHost(rawValue: record.host) else { continue }
            if roots[record.configPath] == nil {
                let url = URL(fileURLWithPath: record.configPath)
                if case .data(let bytes) = read(url) {
                    roots[record.configPath] = try? JSONValue.parse(bytes, maximumDepth: 128)
                } else {
                    roots[record.configPath] = .some(nil)
                }
            }
            guard let root = roots[record.configPath] ?? nil,
                MCPHostSetup.value(at: record.keyPath + [record.name], in: root) == record.written
            else { continue }
            changes.append(MCPRouteChange(
                host: recordHost, path: record.configPath, name: record.name,
                before: rvEntry(record.name, record.written), after: shownEntry(record.name, record.original)))
        }
        return changes
    }

    /// The manifest `rv mcp setup` and `rv mcp add` keep in `configDirectory`.
    public static func setupRecords(configDirectory: URL) -> [MCPSetupRecord] {
        MCPHostSetup.loadManifest(configDirectory)
    }

    /// `"name": {…}` on one line, with no secret value in it.
    public static func shownEntry(_ name: String, _ entry: JSONValue) -> String {
        MCPDisplayedText.field(JSONValue.string(name).compactText + ": " + masked(entry).compactText)
    }

    /// The gateway entry rv writes, exactly: rv's path, `mcp serve` and the
    /// server name hold nothing secret.
    static func rvEntry(_ name: String, _ entry: JSONValue) -> String {
        MCPDisplayedText.field(JSONValue.string(name).compactText + ": " + entry.compactText)
    }

    /// Entry keys whose values hosts use for plain settings. Any other
    /// key's strings are masked whole.
    static let plainKeys: Set<String> = [
        "type", "transport", "mode", "description", "cwd", "enabled", "disabled", "timeout", "trust",
        "alwaysAllow", "autoApprove", "includeTools", "excludeTools",
    ]

    /// `entry` with every value that could be a credential replaced:
    /// environment and header values always, arguments and URLs through
    /// `MCPRedaction`, and any other string that looks like a token.
    static func masked(_ entry: JSONValue) -> JSONValue {
        guard case .object(let object) = entry else { return maskedLeaves(entry) }
        var shown = JSONObject()
        for (key, value) in object.entries {
            switch key {
            case "env", "environment", "headers", "http_headers":
                shown[key] = maskedValues(value)
            case "args":
                shown[key] = value.stringArray.map { .array(MCPRedaction.args($0).shown.map(JSONValue.string)) }
                    ?? maskedLeaves(value)
            case "command":
                if let words = value.stringArray, let first = words.first {
                    let rest = MCPRedaction.args(Array(words.dropFirst())).shown
                    shown[key] = .array(([maskedWord(first)] + rest).map(JSONValue.string))
                } else if let word = value.stringValue {
                    shown[key] = .string(maskedWord(word))
                } else {
                    shown[key] = maskedLeaves(value)
                }
            case "url", "httpUrl", "serverUrl":
                shown[key] = value.stringValue.map { .string(MCPRedaction.url($0).display) } ?? maskedLeaves(value)
            default:
                shown[key] = plainKeys.contains(key) ? maskedLeaves(value) : maskedValues(value)
            }
        }
        return .object(shown)
    }

    static func maskedWord(_ word: String) -> String {
        MCPRedaction.looksLikeToken(word) || MCPRedaction.valueCarriesSecret(word) ? MCPRedaction.mask : word
    }

    /// Every string inside `value` masked: names stay, values never show.
    static func maskedValues(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var shown = JSONObject()
            for (key, item) in object.entries { shown[key] = maskedValues(item) }
            return .object(shown)
        case .array(let items): return .array(items.map(maskedValues))
        case .string: return .string(MCPRedaction.mask)
        case .null, .bool, .number: return value
        }
    }

    static func maskedLeaves(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var shown = JSONObject()
            for (key, item) in object.entries {
                shown[key] = MCPRedaction.isSecretName(key) ? maskedValues(item) : maskedLeaves(item)
            }
            return .object(shown)
        case .array(let items): return .array(items.map(maskedLeaves))
        case .string(let text):
            if text.contains("://") { return .string(MCPRedaction.url(text).display) }
            return .string(maskedWord(text))
        case .null, .bool, .number: return value
        }
    }
}

extension MCPHost {
    /// The host's name as a person knows it.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .gemini: "Gemini"
        case .antigravity: "Antigravity"
        case .vscode: "VS Code"
        case .windsurf: "Windsurf"
        case .muse: "Muse"
        }
    }

    /// The host a person typed: its raw value (`claude-code`, `cursor`),
    /// or `claude` for Claude Code, as the MCP gateway page spells it.
    public init?(word: String) {
        let folded = word.lowercased()
        if folded == "claude" {
            self = .claudeCode
        } else if let host = MCPHost(rawValue: folded) {
            self = host
        } else {
            return nil
        }
    }
}
