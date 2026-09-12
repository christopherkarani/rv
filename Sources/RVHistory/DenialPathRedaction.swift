public enum DenialPathRedaction {
    /// Replace a home prefix with `~`. Does not invent a home.
    public static func redact(_ path: String, home: String?) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let home, home.isEmpty == false else { return trimmed }
        if trimmed == home { return "~" }
        if trimmed.hasPrefix(home + "/") {
            return "~" + trimmed.dropFirst(home.count)
        }
        if trimmed.hasPrefix("$HOME") {
            return "~" + trimmed.dropFirst(5)
        }
        if trimmed.hasPrefix("${HOME}") {
            return "~" + trimmed.dropFirst(7)
        }
        return trimmed
    }
}
