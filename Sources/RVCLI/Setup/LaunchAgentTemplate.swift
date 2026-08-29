import Foundation

enum LaunchAgentTemplate {
    static let rvdPlaceholder = "@RVD_PATH@"

    static func rendered(rvdPath: String, keepAlive: Bool = false) throws(SetupError) -> String {
        let withRvd = try render(
            try raw(),
            placeholder: rvdPlaceholder,
            with: rvdPath
        )
        return try applyingKeepAlive(withRvd, keepAlive: keepAlive)
    }

    private static func raw() throws(SetupError) -> String {
        try decode(PackageResources.dev_rv_evaluate_plist)
    }

    private static func decode(_ bytes: [UInt8]) throws(SetupError) -> String {
        guard let text = String(bytes: bytes, encoding: .utf8), text.isEmpty == false else {
            throw SetupError.launchAgentTemplateMissing
        }
        return text
    }

    private static func render(
        _ raw: String,
        placeholder: String,
        with value: String
    ) throws(SetupError) -> String {
        guard raw.contains(placeholder) else {
            throw SetupError.launchAgentTemplateMissing
        }
        return raw.replacingOccurrences(of: placeholder, with: value)
    }

    // P2-2: string search is low-risk. Template is owned and small (~600 bytes);
    // placeholder is `@RVD_PATH@` which never collides with `<key>KeepAlive</key>`.
    // We render placeholder first, then locate `<key>KeepAlive</key>` and replace the
    // adjacent `<true/>`/`<false/>`. A full plist dict parse would be more robust
    // but adds PropertyListSerialization round-trip and whitespace churn for no
    // functional gain in v1. Keep string path and document the coupling.
    private static func applyingKeepAlive(_ raw: String, keepAlive: Bool) throws(SetupError) -> String {
        guard let keyRange = raw.range(of: "<key>KeepAlive</key>") else {
            throw SetupError.launchAgentTemplateMissing
        }
        let tail = raw[keyRange.upperBound...]
        let trueRange = tail.range(of: "<true/>")
        let falseRange = tail.range(of: "<false/>")
        let boolRange: Range<String.Index>
        switch (trueRange, falseRange) {
        case (let trueMatch?, let falseMatch?):
            boolRange = trueMatch.lowerBound <= falseMatch.lowerBound ? trueMatch : falseMatch
        case (let trueMatch?, nil):
            boolRange = trueMatch
        case (nil, let falseMatch?):
            boolRange = falseMatch
        case (nil, nil):
            throw SetupError.launchAgentTemplateMissing
        }
        let between = tail[..<boolRange.lowerBound]
        guard between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SetupError.launchAgentTemplateMissing
        }
        var rendered = raw
        rendered.replaceSubrange(boolRange, with: keepAlive ? "<true/>" : "<false/>")
        return rendered
    }
}
