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

    public static func denylistFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("denylist.toml", isDirectory: false)
    }

    public static func denylistLockFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(".denylist.lock", isDirectory: false)
    }

    public static func pendingApprovalsFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("pending-approvals.jsonl", isDirectory: false)
    }

    public static func pendingApprovalsLockFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(".pending-approvals.lock", isDirectory: false)
    }

    public static func typedRulesFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("typed-rules.json", isDirectory: false)
    }

    public static func typedRulesLockFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(".typed-rules.lock", isDirectory: false)
    }

    /// Files T6 / `rv uninstall` must delete when present (policy artifacts + locks).
    public static func uninstallArtifacts(inConfigDir configDir: URL) -> [URL] {
        [
            allowlistFile(inConfigDir: configDir),
            allowOnceFile(inConfigDir: configDir),
            allowOnceLockFile(inConfigDir: configDir),
            allowlistLockFile(inConfigDir: configDir),
            denylistFile(inConfigDir: configDir),
            denylistLockFile(inConfigDir: configDir),
            pendingApprovalsFile(inConfigDir: configDir),
            pendingApprovalsLockFile(inConfigDir: configDir),
            typedRulesFile(inConfigDir: configDir),
            typedRulesLockFile(inConfigDir: configDir),
        ]
    }

    /// `$HOME/.config/rv` from process `HOME` only. Never reads `XDG_CONFIG_HOME`.
    public static func configDirectory(home: HomeDirectory) -> URL {
        URL(fileURLWithPath: home.rawValue, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
    }
}
