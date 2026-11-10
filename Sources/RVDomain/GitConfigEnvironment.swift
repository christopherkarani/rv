/// Environment variables through which git reads configuration that never
/// appears on its command line: `GIT_CONFIG_COUNT`/`KEY_n`/`VALUE_n`,
/// `GIT_CONFIG_PARAMETERS`, and the config-file pointers. One list, shared
/// by the gate (which cannot see such config) and the isolation cage
/// (which strips it).
public enum GitConfigEnvironment {
    /// Exact names (uppercased) that point git at another config file.
    public static let configFileNames: Set<String> = [
        "GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM",
    ]

    /// Name prefix (uppercased) of every `GIT_CONFIG_*` variable, including
    /// the count/key/value triplets and `GIT_CONFIG_PARAMETERS`.
    public static let configPrefix = "GIT_CONFIG_"

    /// True when `name` hands git configuration from the environment.
    public static func suppliesConfig(_ name: String) -> Bool {
        let upper = name.uppercased()
        return configFileNames.contains(upper) || upper.hasPrefix(configPrefix)
    }
}
