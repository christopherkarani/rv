import Foundation

enum HostTemplates {
    static func grokHook(rvPath: String) throws -> String {
        try render(resource: "rv", ext: "json.tmpl", replacing: rvPath)
    }

    static func piExtension(rvPath: String) throws -> String {
        try render(resource: "rv-guard", ext: "ts.tmpl", replacing: rvPath)
    }

    static func openCodePlugin(rvPath: String) throws -> String {
        try render(resource: "rv-guard", ext: "js.tmpl", replacing: rvPath)
    }

    static func launchAgentPlist(rvdPath: String) throws -> String {
        let url = try requireURL(resource: "dev.rv.evaluate", ext: "plist", subdirectory: "launchd")
        let raw = try String(contentsOf: url, encoding: .utf8)
        return raw.replacingOccurrences(of: "@RVD_PATH@", with: rvdPath)
    }

    static func isCurrentGrokHook(_ text: String) -> Bool {
        text.contains("PreToolUse")
            && text.contains("\"matcher\": \"Bash\"")
            && text.contains("hook --host grok")
            && text.contains("\"type\": \"command\"")
    }

    static func isCurrentPiExtension(_ text: String) -> Bool {
        text.contains("tool_call")
            && text.contains("[\"hook\", \"--host\", host]")
            && text.contains("spawnRvHook(\"pi\"")
    }

    static func isCurrentOpenCodePlugin(_ text: String) -> Bool {
        text.contains("tool.execute.before")
            && text.contains("[\"hook\", \"--host\", host]")
            && text.contains("spawnRvHook(\"opencode\"")
    }

    private static func render(resource: String, ext: String, replacing rvPath: String) throws -> String {
        let url = try requireURL(resource: resource, ext: ext, subdirectory: "hosts")
        let raw = try String(contentsOf: url, encoding: .utf8)
        return raw.replacingOccurrences(of: "__RV_BINARY__", with: rvPath)
    }

    private static func requireURL(resource: String, ext: String, subdirectory: String) throws -> URL {
        if let url = Bundle.module.url(forResource: resource, withExtension: ext, subdirectory: subdirectory) {
            return url
        }
        if let url = Bundle.module.url(forResource: resource, withExtension: ext) {
            return url
        }
        throw SetupError.missingTemplate("\(subdirectory)/\(resource).\(ext)")
    }
}

enum SetupError: Error, Equatable {
    case missingTemplate(String)
    case missingHome
}
