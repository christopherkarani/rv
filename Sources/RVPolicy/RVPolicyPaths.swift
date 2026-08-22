import Foundation

public enum RVPolicyPaths: Sendable {
    public static func allowlistFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("allowlist.toml", isDirectory: false)
    }

    public static func allowOnceFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("allow-once.jsonl", isDirectory: false)
    }

    public static func allowOnceLockFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(".allow-once.lock", isDirectory: false)
    }

    public static func allowlistLockFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(".allowlist.lock", isDirectory: false)
    }

    /// Files T6 / `rv uninstall` must delete when present (policy artifacts + locks).
    public static func uninstallArtifacts(inConfigDir configDir: URL) -> [URL] {
        [
            allowlistFile(inConfigDir: configDir),
            allowOnceFile(inConfigDir: configDir),
            allowOnceLockFile(inConfigDir: configDir),
            allowlistLockFile(inConfigDir: configDir),
        ]
    }

    /// `$HOME/.config/rv` from process `HOME` only. Never reads `XDG_CONFIG_HOME`.
    public static func configDirectory(home: HomeDirectory) -> URL {
        URL(fileURLWithPath: home.rawValue, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
    }
}
