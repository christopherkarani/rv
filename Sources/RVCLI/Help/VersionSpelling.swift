import RVDomain

/// `rv -V` and `rv version` are the other common spellings of
/// `rv --version`: new users type them first. Each prints the same line.
public enum VersionSpelling {
    static let word = "version"
    static let spellings: Set<[String]> = [["-V"], [word]]

    /// `arguments` with a lone `-V` or `version` turned into `--version`;
    /// anything else unchanged.
    public static func normalized(_ arguments: [String]) -> [String] {
        spellings.contains(arguments) ? ["--version"] : arguments
    }

    /// `rv version --json` and the like: `--version` takes no options, so
    /// neither does its spelling. Says so instead of "unknown command".
    static func refusal(_ arguments: [String]) -> String? {
        guard arguments.first == word, arguments.count > 1 else { return nil }
        let program = CommandVocabulary.program
        return "\(program): \(program) \(word) takes no options; it prints the same line as \(program) --version.\n"
    }
}
