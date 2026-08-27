import Foundation

/// Merge / strip the owned OpenCode TUI Ask package in `opencode.json` and
/// `tui.json`. Official 1.18.18 TUI plugins load from `tui.json` only.
/// File plugins cannot export both `server()` and `tui()`. The globbed
/// `plugins/rv-guard-tui.js` is `{ server() }`. The Ask package exposes
/// only `./tui` so the TUI runtime can paint the official Ask.
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
    import plugin from "../plugins/rv-guard-tui.js";

    function OfficialAsk(props) {
      const active = props.active;
      return (
        <box paddingLeft={2} paddingRight={2} gap={1}>
          <text>{props.title}</text>
          <text>{props.message}</text>
          <box flexDirection="row" justifyContent="flex-end" gap={1}>
            <box paddingLeft={1} paddingRight={1} onMouseUp={() => props.choose(false)}>
              <text>{active === "cancel" ? "> cancel" : "cancel"}</text>
            </box>
            <box paddingLeft={1} paddingRight={1} onMouseUp={() => props.choose(true)}>
              <text>{active === "confirm" ? "> confirm" : "confirm"}</text>
            </box>
          </box>
        </box>
      );
    }

    export default {
      id: "rv-guard-tui-ask",
      tui: async (api, options, meta) => {
        if (api && api.ui) {
          api.ui.paintOfficialAsk = (view, finish) =>
            OfficialAsk({
              title: view.title,
              message: view.message,
              active: view.active,
              choose: finish,
            });
        }
        return plugin.server(api, options, meta);
      },
    };
    """
}
