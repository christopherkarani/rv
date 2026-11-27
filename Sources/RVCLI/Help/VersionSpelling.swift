/// `rv -V` and `rv version` are the other common spellings of
/// `rv --version`: new users type them first. Each prints the same line.
public enum VersionSpelling {
    static let spellings: Set<[String]> = [["-V"], ["version"]]

    /// `arguments` with a lone `-V` or `version` turned into `--version`;
    /// anything else unchanged.
    public static func normalized(_ arguments: [String]) -> [String] {
        spellings.contains(arguments) ? ["--version"] : arguments
    }
}
