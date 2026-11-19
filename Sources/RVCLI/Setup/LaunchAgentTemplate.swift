import Foundation

enum LaunchAgentTemplate {
    static let rvdPlaceholder = "@RVD_PATH@"
    static let custodianPlaceholder = "@CUSTODIAN_PATH@"

    static func rendered(rvdPath: String) throws(SetupError) -> String {
        try render(try raw(), placeholder: rvdPlaceholder, with: rvdPath)
    }

    static func renderedCustodian(custodianPath: String) throws(SetupError) -> String {
        try render(
            try decode(PackageResources.dev_rv_mcp_custodian_plist),
            placeholder: custodianPlaceholder,
            with: custodianPath
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
