import Foundation

/// Merge / strip the owned OpenCode TUI Ask package in `opencode.json` and
/// `tui.json`. Official 1.18.18 TUI plugins load from `tui.json` only.
/// File plugins cannot export both `server()` and `tui()`. The globbed
/// `plugins/rv-guard-tui.js` is `{ server() }`. The Ask package exposes
/// only `./tui` so leftover custom DialogConfirm installs are replaced.
/// Live 1.18.18 TUI mounts host PermissionPrompt from `sync.data.permission`
/// filled on V1 asked (`Permission.ask` / Tool.Context `ctx.ask` in
/// `packages/opencode/src/tool/shell.ts`). Official plugin create is V2
/// (`permission.v2.asked`) only. TUI sync does not handle that event.
/// There is no HTTP V1 create. Desktop `adaptServerEvent` is not in TUI.
/// Plugin `useSync().set` / V1 emit is not official create — do not ship it.
/// A plugin cannot call `ctx.ask`. Smallest official hook: plugin-callable
/// `Permission.ask`, or TUI `adaptServerEvent` for V2 asked, plus a
/// post-Return spend hook.
/// This package overwrites leftover DialogConfirm installs with a no-op.
enum OpenCodeConfigMerge {
    static func merge(existingData: Data?, pluginPath: String) throws -> (data: Data, wrote: Bool) {
        var root = try parseRoot(existingData)
        var plugins = pluginList(from: root)
        if plugins.contains(where: { pluginSpecifier($0) == pluginPath }) {
            let data = try encode(root)
            return (data, existingData != data)
        }
        plugins.append(pluginPath)
        root["plugin"] = plugins
        let data = try encode(root)
        return (data, existingData != data)
    }

    static func strip(existingData: Data?, pluginPath: String) throws -> Data? {
        guard let existingData else {
            return nil
        }
        var root = try parseRoot(existingData)
        let plugins = pluginList(from: root).filter { pluginSpecifier($0) != pluginPath }
        if plugins.isEmpty {
            root.removeValue(forKey: "plugin")
        } else {
            root["plugin"] = plugins
        }
        if root.isEmpty {
            return nil
        }
        return try encode(root)
    }

    private static func parseRoot(_ existingData: Data?) throws -> [String: Any] {
        guard let existingData, existingData.isEmpty == false else {
            return [:]
        }
        let object = try JSONSerialization.jsonObject(with: existingData)
        guard let root = object as? [String: Any] else {
            throw OpenCodeConfigMergeError.invalidJSON
        }
        return root
    }

    private static func pluginList(from root: [String: Any]) -> [Any] {
        guard let plugin = root["plugin"] else {
            return []
        }
        if let list = plugin as? [Any] {
            return list
        }
        return [plugin]
    }

    private static func pluginSpecifier(_ plugin: Any) -> String? {
        if let spec = plugin as? String {
            return spec
        }
        if let pair = plugin as? [Any], let spec = pair.first as? String {
            return spec
        }
        return nil
    }

    private static func encode(_ root: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw OpenCodeConfigMergeError.invalidJSON
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
    }
}

enum OpenCodeConfigMergeError: Error, Equatable, Sendable {
    case invalidJSON
}

enum OpenCodeTuiAskPackage {
    static let packageJSON = """
    {
      "name": "rv-guard-tui-ask",
      "type": "module",
      "exports": {
        "./tui": "./tui.tsx"
      }
    }
    """

    static let tuiTSX = """
    /** @jsxImportSource @opentui/solid */
    /** Official paint is Tool.Context ctx.ask (Permission.ask / shell.ts). Plugin cannot call it. */
    export default {
      id: "rv-guard-tui-ask",
      tui: async () => ({}),
    };
    """
}
