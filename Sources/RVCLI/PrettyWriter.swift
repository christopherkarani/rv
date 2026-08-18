enum PrettyWriter {
    static func join(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }
}
