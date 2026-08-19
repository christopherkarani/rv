import Foundation

enum HostTemplates {
    static let rvPlaceholder = "__RV_BINARY__"
    static let rvdPlaceholder = "@RVD_PATH@"

    static func grokHook(rvPath: String) throws -> String {
        try render(try rawGrok(), name: "hosts/rv.json.tmpl", placeholder: rvPlaceholder, with: rvPath)
    }

    static func piExtension(rvPath: String) throws -> String {
        try render(try rawPi(), name: "hosts/rv-guard.ts.tmpl", placeholder: rvPlaceholder, with: rvPath)
    }

    static func openCodePlugin(rvPath: String) throws -> String {
        try render(try rawOpenCode(), name: "hosts/rv-guard.js.tmpl", placeholder: rvPlaceholder, with: rvPath)
    }

    static func launchAgentPlist(rvdPath: String) throws -> String {
        try render(
            try rawLaunchAgent(),
            name: "launchd/dev.rv.evaluate.plist",
            placeholder: rvdPlaceholder,
            with: rvdPath
        )
    }

    static func rawGrok() throws -> String {
        try decode(PackageResources.rv_json_tmpl, name: "hosts/rv.json.tmpl")
    }

    static func rawPi() throws -> String {
        try decode(PackageResources.rv_guard_ts_tmpl, name: "hosts/rv-guard.ts.tmpl")
    }

    static func rawOpenCode() throws -> String {
        try decode(PackageResources.rv_guard_js_tmpl, name: "hosts/rv-guard.js.tmpl")
    }

    static func rawLaunchAgent() throws -> String {
        try decode(PackageResources.dev_rv_evaluate_plist, name: "launchd/dev.rv.evaluate.plist")
    }

    /// True when `existing` is the raw template with a single substitution for `placeholder`
    /// (any baked path). Extra keys or hooks make this false.
    static func matchesCurrentTemplate(
        _ existing: String,
        raw: String,
        placeholder: String = rvPlaceholder
    ) -> Bool {
        let parts = raw.components(separatedBy: placeholder)
        guard parts.count > 1 else { return existing == raw }
        let prefix = parts[0]
        guard existing.hasPrefix(prefix) else { return false }
        let afterPrefix = existing.dropFirst(prefix.count)
        let second = parts[1]
        let substitution: String
        if second.isEmpty {
            substitution = String(afterPrefix)
        } else {
            guard let range = afterPrefix.range(of: second) else { return false }
            substitution = String(afterPrefix[..<range.lowerBound])
        }
        return parts.joined(separator: substitution) == existing
    }

    private static func decode(_ bytes: [UInt8], name: String) throws -> String {
        guard let text = String(bytes: bytes, encoding: .utf8), text.isEmpty == false else {
            throw SetupError.missingTemplate(name)
        }
        return text
    }

    private static func render(
        _ raw: String,
        name: String,
        placeholder: String,
        with value: String
    ) throws -> String {
        guard raw.contains(placeholder) else {
            throw SetupError.missingTemplate(name)
        }
        return raw.replacingOccurrences(of: placeholder, with: value)
    }
}

enum SetupError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case missingTemplate(String)

    var description: String {
        switch self {
        case .missingTemplate(let name):
            return "missing template \(name)"
        }
    }

    var errorDescription: String? { description }
}
