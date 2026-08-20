import Foundation

public enum RVPolicyPaths: Sendable {
    public static func allowlistFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("allowlist.toml", isDirectory: false)
    }

    public static func allowOnceFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("allow-once.jsonl", isDirectory: false)
    }

    /// `$HOME/.config/rv` from process `HOME` only. Never reads `XDG_CONFIG_HOME`.
    public static func configDirectory(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
    }
}
