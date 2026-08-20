import Foundation

enum LaunchAgentTemplate {
    static let rvdPlaceholder = "@RVD_PATH@"

    static func rendered(rvdPath: String) throws -> String {
        try render(
            try raw(),
            name: "launchd/dev.rv.evaluate.plist",
            placeholder: rvdPlaceholder,
            with: rvdPath
        )
    }

    static func raw() throws -> String {
        try decode(PackageResources.dev_rv_evaluate_plist, name: "launchd/dev.rv.evaluate.plist")
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
