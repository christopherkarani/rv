import Foundation

enum LaunchAgentTemplate {
    static let rvdPlaceholder = "@RVD_PATH@"

    static func rendered(rvdPath: String) throws(SetupError) -> String {
        try render(
            try raw(),
            placeholder: rvdPlaceholder,
            with: rvdPath
        )
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
}
