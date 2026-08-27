import Foundation

/// Merge / strip the owned OpenCode TUI Ask package in `opencode.json` and
/// `tui.json`. Official 1.18.18 TUI plugins load from `tui.json` only.
/// File plugins cannot export both `server()` and `tui()`. The globbed
/// `plugins/rv-guard-tui.js` is `{ server() }`. The Ask package exposes
/// only `./tui` so leftover custom DialogConfirm installs are replaced.
/// Live 1.18.18 TUI mounts host PermissionPrompt from `sync.data.permission`.
/// Official plugin create is V2 (`permission.v2.asked`); TUI sync does not
/// handle that event. There is no HTTP V1 create. `tui.tsx` imports host
/// `useSDK` / `useSync` and the companion writes the V1 row through
/// `useSync().set` only — it does not emit a synthetic V1 asked (official
/// `--auto` would reply without Return). Return is shimmed on
/// `useSDK().client`, the object PermissionPrompt calls. A dynamic import
/// from `plugins/rv-guard-tui.js` cannot resolve `@opencode-ai/tui`.
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
    import { useSDK } from "@opencode-ai/tui/context/sdk";
    import { useSync } from "@opencode-ai/tui/context/sync";
    import plugin from "../plugins/rv-guard-tui.js";

    export default {
      id: "rv-guard-tui-ask",
      tui: async (api, options, meta) => {
        return plugin.server(api, options, meta, { useSDK, useSync });
      },
    };
    """
}
