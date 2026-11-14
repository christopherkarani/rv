import Foundation
import RVDomain

/// MCP sources `rv mcp setup` never rewrites: Claude Code's system managed
/// files and the MCP servers its plugins declare. Locations come from
/// `MCPHostConfigLocation`, the table the hook guard reads.
///
/// Plugins: every install `installed_plugins.json` records (user and
/// managed scope; project and local scope only for the inventoried
/// project), plus skills-directory plugins under `~/.claude/skills/` and the
/// project's `.claude/skills/`. Each plugin's root `.mcp.json` and its
/// manifest's `mcpServers` (inline object, a file path inside the plugin, or
/// an array of either) are read. A plugin the owner turned off in
/// `enabledPlugins` (user, project, local or managed settings) is disabled.
enum MCPReadOnlySources {
    static func files(
        home: URL,
        project: URL?,
        environment: [String: String],
        managedDirectory: String,
        read: (URL) -> MCPInventory.HostFile,
        list: (URL) -> [String],
        problems: inout [MCPInventoryProblem]
    ) -> [MCPHostFile] {
        var files: [MCPHostFile] = []
        for location in MCPHostConfigLocation.allCases {
            switch location {
            case .claudeCodeManagedMCP:
                files.append(managed(managedDirectory, "managed-mcp.json", keyPath: ["mcpServers"]))
            case .claudeCodeManagedSettings:
                files.append(managed(managedDirectory, "managed-settings.json", keyPath: ["managedMcpServers"]))
            case .claudeCodeManagedSettingsDropIns:
                let directory = URL(fileURLWithPath: managedDirectory, isDirectory: true)
                    .appendingPathComponent("managed-settings.d", isDirectory: true)
                for name in list(directory).sorted() where name.hasSuffix(".json") && name.hasPrefix(".") == false {
                    files.append(managed(directory.path, name, keyPath: ["managedMcpServers"]))
                }
            case .claudeCodePlugins:
                let enabled = PluginSwitches.load(
                    home: home, project: project, managedDirectory: managedDirectory, read: read)
                let found = plugins(
                    home: home, project: project, environment: environment, read: read, list: list,
                    problems: &problems)
                for plugin in found {
                    files += pluginFiles(plugin, disabled: enabled.isDisabled(plugin.id), read: read)
                }
            case .claudeCodeUser, .claudeDesktopUser, .cursorUser, .codexUser, .opencodeUser, .opencodeUserJSONC,
                 .geminiUser, .antigravityUser, .vscodeUser, .windsurfUser, .museUser, .claudeCodeProject,
                 .cursorProject, .vscodeProject, .opencodeProject, .geminiProject:
                continue
            }
        }
        return files
    }

    private static func managed(_ directory: String, _ name: String, keyPath: [String]) -> MCPHostFile {
        MCPHostFile(
            host: .claudeCode, scope: .managed,
            path: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name, isDirectory: false),
            format: .json(keyPath: keyPath, lenient: false, opencode: false))
    }

    struct Plugin: Equatable {
        var id: String
        var root: URL
    }

    /// Installed and skills-directory plugin roots, in a stable order.
    static func plugins(
        home: URL, project: URL?, environment: [String: String],
        read: (URL) -> MCPInventory.HostFile, list: (URL) -> [String],
        problems: inout [MCPInventoryProblem]
    ) -> [Plugin] {
        var found: [Plugin] = []
        let pluginsRoot = environment["CLAUDE_CODE_PLUGIN_CACHE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: MCPHostConfigLocation.claudeCodePlugins.path(
                home: home.path, codexHome: nil, project: nil) ?? home.path, isDirectory: true)
        let records = pluginsRoot.appendingPathComponent("installed_plugins.json", isDirectory: false)
        let wantedProject = project.map { MCPInventory.canonicalProjectPath($0.path) }
        var installs: JSONObject?
        switch read(records) {
        case .missing:
            break
        case .unreadable(let message):
            problems.append(MCPInventoryProblem(path: records.path, message: message))
        case .data(let data):
            if let root = try? JSONValue.parse(data, maximumDepth: 64) {
                installs = root["plugins"]?.objectValue
            } else {
                problems.append(MCPInventoryProblem(path: records.path, message: "could not parse JSON"))
            }
        }
        if let installs {
            for (id, value) in installs.entries {
                for install in value.arrayValue ?? [] {
                    guard let path = install["installPath"]?.stringValue, path.hasPrefix("/") else { continue }
                    switch install["scope"]?.stringValue ?? "user" {
                    case "project", "local":
                        guard let wantedProject, let owner = install["projectPath"]?.stringValue,
                              MCPInventory.canonicalProjectPath(owner) == wantedProject
                        else { continue }
                    default:
                        break
                    }
                    let plugin = Plugin(id: id, root: URL(fileURLWithPath: path, isDirectory: true))
                    if found.contains(plugin) == false { found.append(plugin) }
                }
            }
        }
        var skillDirectories = [home.appendingPathComponent(".claude/skills", isDirectory: true)]
        if let project { skillDirectories.append(project.appendingPathComponent(".claude/skills", isDirectory: true)) }
        for directory in skillDirectories {
            for name in list(directory).sorted() where name.hasPrefix(".") == false {
                let root = directory.appendingPathComponent(name, isDirectory: true)
                let manifest = MCPHostConfigPaths.pluginManifest.reduce(root) {
                    $0.appendingPathComponent($1, isDirectory: false)
                }
                guard case .data(let data) = read(manifest) else { continue }
                let manifestName = (try? JSONValue.parse(data, maximumDepth: 64))?["name"]?.stringValue ?? name
                let plugin = Plugin(id: "\(manifestName)@skills-dir", root: root)
                if found.contains(plugin) == false { found.append(plugin) }
            }
        }
        return found
    }

    /// The plugin's `.mcp.json`, its manifest (inline servers), and every
    /// file the manifest's `mcpServers` names inside the plugin.
    static func pluginFiles(_ plugin: Plugin, disabled: Bool, read: (URL) -> MCPInventory.HostFile) -> [MCPHostFile] {
        let scope = MCPEntryScope.plugin(plugin.id)
        func file(_ url: URL, _ format: MCPHostFile.Format) -> MCPHostFile {
            MCPHostFile(host: .claudeCode, scope: scope, path: url, format: format)
        }
        let manifest = MCPHostConfigPaths.pluginManifest.reduce(plugin.root) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        var files = [
            file(plugin.root.appendingPathComponent(".mcp.json", isDirectory: false), .pluginServers(disabled: disabled)),
            file(manifest, .pluginManifest(disabled: disabled)),
        ]
        guard case .data(let data) = read(manifest),
              let declared = (try? JSONValue.parse(data, maximumDepth: 64))?["mcpServers"]
        else { return files }
        let paths: [String]
        switch declared {
        case .string(let path): paths = [path]
        case .array(let items): paths = items.compactMap(\.stringValue)
        default: paths = []
        }
        let rootPath = plugin.root.standardizedFileURL.path
        for path in paths {
            let expanded = path.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: rootPath)
            let url = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded, isDirectory: false)
                : plugin.root.appendingPathComponent(expanded, isDirectory: false)
            // Claude Code refuses component paths that leave the plugin.
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(rootPath + "/"), standardized.pathExtension.lowercased() == "json"
            else { continue }
            if files.contains(where: { $0.path.standardizedFileURL == standardized }) { continue }
            files.append(file(standardized, .pluginServers(disabled: disabled)))
        }
        return files
    }
}

/// `enabledPlugins` across Claude Code settings, lowest precedence first:
/// user, project, local, managed. The highest source naming an id wins.
struct PluginSwitches {
    var values: [String: Bool] = [:]

    func isDisabled(_ id: String) -> Bool { values[id] == false }

    static func load(
        home: URL, project: URL?, managedDirectory: String, read: (URL) -> MCPInventory.HostFile
    ) -> PluginSwitches {
        var sources = [home.appendingPathComponent(".claude/settings.json", isDirectory: false)]
        if let project {
            sources.append(project.appendingPathComponent(".claude/settings.json", isDirectory: false))
            sources.append(project.appendingPathComponent(".claude/settings.local.json", isDirectory: false))
        }
        sources.append(URL(fileURLWithPath: managedDirectory, isDirectory: true)
            .appendingPathComponent("managed-settings.json", isDirectory: false))
        var switches = PluginSwitches()
        for source in sources {
            guard case .data(let data) = read(source),
                  let enabled = (try? JSONValue.parse(data, maximumDepth: 64, lenient: true))?["enabledPlugins"]?
                    .objectValue
            else { continue }
            for (id, value) in enabled.entries {
                if let flag = value.boolValue { switches.values[id] = flag }
            }
        }
        return switches
    }
}
