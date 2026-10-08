import Foundation
import RVDomain

/// Merge / strip the owned OpenCode TUI Ask package in `opencode.json`.
/// Official 1.18.18 file plugins cannot export both `server()` and `tui()`.
/// The globbed `plugins/rv-guard-tui.js` is `{ server() }`. The Ask package
/// exposes only `./tui` so the TUI runtime can paint DialogConfirm.
enum OpenCodeConfigMerge {
    static func merge(existingData: Data?, pluginPath: String) throws -> (data: Data, wrote: Bool) {
        var root = try parseRoot(existingData)
        var plugins = pluginList(from: root)
        if plugins.contains(where: { pluginSpecifier($0) == pluginPath }) {
            let data = try encode(root)
            return (data, existingData != data)
        }
        plugins.append(.string(pluginPath))
        root["plugin"] = .array(plugins)
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
            root["plugin"] = .array(plugins)
        }
        if root.isEmpty {
            return nil
        }
        return try encode(root)
    }

    private static func parseRoot(_ existingData: Data?) throws -> [String: JSONValue] {
        guard let existingData, existingData.isEmpty == false else {
            return [:]
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: existingData),
              let root = value.asObject
        else {
            throw OpenCodeConfigMergeError.invalidJSON
        }
        return root
    }

    private static func pluginList(from root: [String: JSONValue]) -> [JSONValue] {
        guard let plugin = root["plugin"] else {
            return []
        }
        if let list = plugin.asArray {
            return list
        }
        return [plugin]
    }

    private static func pluginSpecifier(_ plugin: JSONValue) -> String? {
        if let spec = plugin.string {
            return spec
        }
        if let pair = plugin.asArray, let spec = pair.first?.string {
            return spec
        }
        return nil
    }

    private static func encode(_ root: [String: JSONValue]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(JSONValue.object(root)) else {
            throw OpenCodeConfigMergeError.invalidJSON
        }
        return data
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
        "./tui": "./tui.js"
      }
    }
    """

    static let tuiJS = """
    import plugin from "../plugins/rv-guard-tui.js";

    export default {
      id: "rv-guard-tui-ask",
      tui: plugin.server,
    };
    """
}
