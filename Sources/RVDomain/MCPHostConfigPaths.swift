import Foundation

/// Where an agent host keeps the MCP servers it launches. One table for
/// `rv mcp check` / `rv report` (RVMCP maps each case to a host and a
/// format with an exhaustive switch) and for the hook guard that keeps an
/// agent from adding ungoverned servers while rv's MCP gateway is in use.
public enum MCPHostConfigLocation: String, CaseIterable, Sendable {
    case claudeCodeUser
    case claudeDesktopUser
    case cursorUser
    case codexUser
    case opencodeUser
    case opencodeUserJSONC
    case geminiUser
    case antigravityUser
    case vscodeUser
    case windsurfUser
    case museUser
    case claudeCodeProject
    case cursorProject
    case vscodeProject
    case opencodeProject
    case geminiProject
    /// Claude Code's system-wide `managed-mcp.json` (same shape as `.mcp.json`).
    case claudeCodeManagedMCP
    /// `managedMcpServers` in Claude Code's system `managed-settings.json`.
    case claudeCodeManagedSettings
    /// `managed-settings.d/*.json` drop-ins merged with `managed-settings.json`.
    case claudeCodeManagedSettingsDropIns
    /// Claude Code's plugins root: install records and every cached plugin,
    /// each of which may declare MCP servers.
    case claudeCodePlugins

    /// `MCPHost` raw value in RVMCP.
    public var host: String {
        switch self {
        case .claudeCodeUser, .claudeCodeProject, .claudeCodeManagedMCP, .claudeCodeManagedSettings,
             .claudeCodeManagedSettingsDropIns, .claudeCodePlugins:
            "claude-code"
        case .claudeDesktopUser: "claude-desktop"
        case .cursorUser, .cursorProject: "cursor"
        case .codexUser: "codex"
        case .opencodeUser, .opencodeUserJSONC, .opencodeProject: "opencode"
        case .geminiUser, .geminiProject: "gemini"
        case .antigravityUser: "antigravity"
        case .vscodeUser, .vscodeProject: "vscode"
        case .windsurfUser: "windsurf"
        case .museUser: "muse"
        }
    }

    public var anchor: MCPHostConfigAnchor {
        switch self {
        case .claudeCodeUser: .home([".claude.json"])
        case .claudeDesktopUser: .home(MCPHostConfigPaths.claudeDesktopComponents)
        case .cursorUser: .home([".cursor", "mcp.json"])
        case .codexUser: .codexHome(["config.toml"])
        case .opencodeUser: .home([".config", "opencode", "opencode.json"])
        case .opencodeUserJSONC: .home([".config", "opencode", "opencode.jsonc"])
        case .geminiUser: .home([".gemini", "settings.json"])
        case .antigravityUser: .home([".gemini", "antigravity", "mcp_config.json"])
        case .vscodeUser: .home(MCPHostConfigPaths.vscodeUserComponents)
        case .windsurfUser: .home([".codeium", "windsurf", "mcp_config.json"])
        case .museUser: .home([".config", "muse", "settings.json"])
        case .claudeCodeProject: .project([".mcp.json"])
        case .cursorProject: .project([".cursor", "mcp.json"])
        case .vscodeProject: .project([".vscode", "mcp.json"])
        case .opencodeProject: .project(["opencode.json"])
        case .geminiProject: .project([".gemini", "settings.json"])
        case .claudeCodeManagedMCP: .system(MCPHostConfigPaths.claudeCodeManagedDirectory + "/managed-mcp.json")
        case .claudeCodeManagedSettings:
            .system(MCPHostConfigPaths.claudeCodeManagedDirectory + "/managed-settings.json")
        case .claudeCodeManagedSettingsDropIns:
            .system(MCPHostConfigPaths.claudeCodeManagedDirectory + "/managed-settings.d")
        case .claudeCodePlugins: .home([".claude", "plugins"])
        }
    }

    /// A directory whose whole subtree is host MCP configuration.
    public var isTree: Bool {
        switch self {
        case .claudeCodeManagedSettingsDropIns, .claudeCodePlugins: true
        default: false
        }
    }

    /// Absolute path for this home / Codex home / project. `codexHome` nil
    /// means `~/.codex`; nil result when a project location has no project.
    public func path(home: String, codexHome: String?, project: String?) -> String? {
        switch anchor {
        case .home(let parts): return MCPHostConfigPaths.join(home, parts)
        case .codexHome(let parts): return MCPHostConfigPaths.join(codexHome ?? home + "/.codex", parts)
        case .project(let parts): return project.map { MCPHostConfigPaths.join($0, parts) }
        case .system(let absolute): return absolute
        }
    }
}

public enum MCPHostConfigAnchor: Sendable, Equatable {
    /// Components below the home directory.
    case home([String])
    /// Components below `$CODEX_HOME` (default `~/.codex`).
    case codexHome([String])
    /// Components below a project root; the guard matches the shape in any directory.
    case project([String])
    /// An absolute path.
    case system(String)
}

/// The hook guard over `MCPHostConfigLocation`. Matching is lexical and
/// pure: callers pass absolute (or `~`/`$HOME`-prefixed) normalized paths,
/// plus resolved forms when they have them. Case-insensitive on Darwin.
///
/// Guarded: every home-anchored file at its exact path, the Codex default
/// `~/.codex/config.toml` (rvd cannot see an agent's `CODEX_HOME`), every
/// project shape in any directory, Claude Code's system managed files, the
/// whole plugins root and managed drop-in directory, and any plugin manifest
/// (`.claude-plugin/plugin.json`, whose `mcpServers` is loaded from
/// skills-directory plugins too).
public enum MCPHostConfigPaths {
    public static let pattern = "mcp-host-config"
    public static let ruleID = RuleID(pack: .coreMCP, pattern: pattern)
    public static let reason =
        "rv's MCP gateway is in use: agent host MCP configs can only be changed with your approval."

    /// rv's own gateway config in its config directory (`rv mcp import`):
    /// while it exists the gateway is in use and the guard is on.
    public static let gatewayConfigFileName = "mcp.json"

    /// Claude Code plugin manifest, relative to a plugin root.
    public static let pluginManifest = [".claude-plugin", "plugin.json"]

    #if os(macOS)
    public static let claudeCodeManagedDirectory = "/Library/Application Support/ClaudeCode"
    static let claudeDesktopComponents = ["Library", "Application Support", "Claude", "claude_desktop_config.json"]
    static let vscodeUserComponents = ["Library", "Application Support", "Code", "User", "mcp.json"]
    #else
    public static let claudeCodeManagedDirectory = "/etc/claude-code"
    static let claudeDesktopComponents = [".config", "Claude", "claude_desktop_config.json"]
    static let vscodeUserComponents = [".config", "Code", "User", "mcp.json"]
    #endif

    /// Whether writing `path` changes a host MCP config.
    public static func isGuarded(_ path: String, home: String) -> Bool {
        let components = absoluteComponents(path, home: home)
        guard components.isEmpty == false else { return false }
        if anchoredEntries(home: home).contains(where: { hasPrefix(components, $0.parts, exact: $0.isTree == false) }) {
            return true
        }
        return shapes.contains { hasSuffix(components, $0) }
    }

    /// Whether `path` is a directory that holds a guarded file (below home,
    /// or a project shape's directory such as `.cursor`): moving onto it or
    /// copying into it lands a guarded file. Home itself and `/` are not.
    public static func isGuardedContainer(_ path: String, home: String) -> Bool {
        let components = absoluteComponents(path, home: home)
        guard components.isEmpty == false else { return false }
        let anchored = anchoredEntries(home: home).contains { entry in
            components.count < entry.parts.count && components.count >= entry.shallowestContainer
                && hasPrefix(entry.parts, components, exact: false)
        }
        if anchored { return true }
        guard let last = components.last else { return false }
        return shapes.contains { $0.count > 1 && $0[0] == last }
    }

    /// Absolute paths of the fixed guarded files and trees under `home`,
    /// for callers that compare a resolved target against a guarded file's
    /// resolved location (a dotfiles symlink).
    public static func fixedFiles(home: String) -> [String] {
        MCPHostConfigLocation.allCases.compactMap { location in
            guard case .project = location.anchor else {
                return location.path(home: home, codexHome: nil, project: nil)
            }
            return nil
        }
    }

    /// Whether `word` names a guarded file (case-folded substring match on
    /// distinctive names). For commands rv cannot model: a word that never
    /// mentions one of these is not a write rv can attribute to them.
    public static func mentions(_ word: String) -> Bool {
        let folded = foldedPathComponent(word)
        return mentionTokens.contains { folded.contains($0) }
    }

    /// Distinctive names derived from the table: the file name, or
    /// `parent/name` when the name alone is generic.
    public static let mentionTokens: [String] = {
        let generic: Set<String> = ["settings.json", "config.toml", "plugins", "plugin.json"]
        var parts: [[String]] = MCPHostConfigLocation.allCases.map { location in
            switch location.anchor {
            case .home(let parts), .project(let parts): return parts
            case .codexHome(let parts): return [".codex"] + parts
            case .system(let absolute): return absolute.split(separator: "/").map(String.init)
            }
        }
        parts.append(pluginManifest)
        var tokens: [String] = []
        for path in parts {
            guard let name = path.last else { continue }
            let token = generic.contains(name) && path.count > 1 ? path.suffix(2).joined(separator: "/") : name
            let folded = foldedPathComponent(token)
            if tokens.contains(folded) == false { tokens.append(folded) }
        }
        return tokens
    }()

    // MARK: - Matching

    struct AnchoredEntry {
        var parts: [String]
        var isTree: Bool
        /// Depth of the shallowest directory that counts as holding this
        /// entry: just below home for home files, the parent directory for
        /// system files.
        var shallowestContainer: Int
    }

    static func anchoredEntries(home: String) -> [AnchoredEntry] {
        let homeDepth = absoluteComponents(home, home: home).count
        return MCPHostConfigLocation.allCases.compactMap { location in
            guard let path = location.path(home: home, codexHome: nil, project: nil) else { return nil }
            let parts = absoluteComponents(path, home: home)
            switch location.anchor {
            case .project: return nil
            case .system: return AnchoredEntry(parts: parts, isTree: location.isTree, shallowestContainer: parts.count - 1)
            case .home, .codexHome:
                return AnchoredEntry(parts: parts, isTree: location.isTree, shallowestContainer: homeDepth + 1)
            }
        }
    }

    /// Project shapes, matched as a suffix in any directory, plus the
    /// plugin manifest.
    static let shapes: [[String]] = MCPHostConfigLocation.allCases.compactMap { location in
        if case .project(let parts) = location.anchor { return parts.map(foldedPathComponent) }
        return nil
    } + [pluginManifest.map(foldedPathComponent)]

    static func join(_ base: String, _ parts: [String]) -> String {
        var root = base
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        return ([root] + parts).joined(separator: "/")
    }

    /// Folded absolute components; `~`, `$HOME`, `${HOME}` and `~user`
    /// expand. Relative paths have no components.
    static func absoluteComponents(_ path: String, home: String) -> [String] {
        if case .expanded(let expanded) = expandTildeUser(path) {
            return absoluteComponents(expanded, home: home)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let first = components.first, first == "~" || first == "$HOME" || first == "${HOME}" {
            let homeParts = home.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            return (homeParts + components.dropFirst()).map(foldedPathComponent)
        }
        guard path.hasPrefix("/") else { return [] }
        return components.map(foldedPathComponent)
    }

    private static func hasPrefix(_ parts: [String], _ prefix: [String], exact: Bool) -> Bool {
        if exact { return parts == prefix }
        return parts.count >= prefix.count && Array(parts.prefix(prefix.count)) == prefix
    }

    private static func hasSuffix(_ parts: [String], _ suffix: [String]) -> Bool {
        parts.count >= suffix.count && Array(parts.suffix(suffix.count)) == suffix
    }
}
