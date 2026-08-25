import Foundation

enum SystemdUserTemplate {
    static let rvdPlaceholder = "@RVD_PATH@"
    static let unitName = "dev.rv.evaluate.service"

    static func rendered(rvdPath: String) throws(SetupError) -> String {
        try render(
            try raw(),
            placeholder: rvdPlaceholder,
            with: rvdPath
        )
    }

    private static func raw() throws(SetupError) -> String {
        try decode(PackageResources.dev_rv_evaluate_service)
    }

    private static func decode(_ bytes: [UInt8]) throws(SetupError) -> String {
        guard let text = String(bytes: bytes, encoding: .utf8), text.isEmpty == false else {
            throw SetupError.systemdUnitTemplateMissing
        }
        return text
    }

    private static func render(
        _ raw: String,
        placeholder: String,
        with value: String
    ) throws(SetupError) -> String {
        guard raw.contains(placeholder) else {
            throw SetupError.systemdUnitTemplateMissing
        }
        return raw.replacingOccurrences(of: placeholder, with: value)
    }
}
