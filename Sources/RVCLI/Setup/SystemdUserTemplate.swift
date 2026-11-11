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
        return raw.replacingOccurrences(of: placeholder, with: try execStartQuoted(value))
    }

    /// One `ExecStart=` word for `path`: double-quoted so a HOME with spaces
    /// stays one argument, with `\` and `"` escaped and `%` doubled so systemd
    /// does not expand it as a specifier. A newline cannot be expressed in a
    /// unit line at all, so it is refused rather than written torn.
    static func execStartQuoted(_ path: String) throws(SetupError) -> String {
        guard path.contains(where: { $0.isNewline }) == false else {
            throw SetupError.systemdUnitWriteFailed
        }
        var quoted = "\""
        for character in path {
            switch character {
            case "\\": quoted += "\\\\"
            case "\"": quoted += "\\\""
            case "%": quoted += "%%"
            default: quoted.append(character)
            }
        }
        return quoted + "\""
    }
}
