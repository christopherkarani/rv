import Foundation

/// The files that keep rv wired in: agent-host hook registrations and
/// adapters that `rv setup` writes, rv's installed binaries and pack
/// bundle, and its LaunchAgent / systemd user units. An agent that edits
/// one of these unhooks or replaces the guard watching it.
///
/// One table for both doors: the file-tool door denies Edit/Write here,
/// and the shell door classifies these paths as protected, so a write
/// (`sed -i`, `cp`, redirect) denies even from a repository rooted at
/// `$HOME`. Reads stay allowed: these files hold no secret. All shapes are
/// anchored at the home directory; `RVCLITests` pins every `OwnedPaths`
/// destination to this table so setup and the guard cannot drift.
public enum RVWiringPaths {
    public static let pattern = "rv-wiring"
    public static let ruleID = RuleID(pack: .coreSecrets, pattern: pattern)
    public static let reason =
        "rv's hook, service and binary files can only be changed by you, outside the agent."

    /// Home-relative files and directories (the path itself or anything
    /// under it). Hook adapters (`rv-guard*`) match by name below.
    static let homeEntries: [[String]] = [
        [".claude", "settings.json"],
        [".codex", "hooks.json"],
        [".cursor", "hooks.json"],
        [".gemini", "config", "hooks.json"],
        [".grok", "hooks", "rv.json"],
        [".config", "opencode", "opencode.json"],
        [".config", "muse", "settings.json"],
        [".config", "muse", "rv-hooks.json"],
        ["Applications", "RVApprovals.app"],
    ]

    /// Home-relative directories whose `dev.rv.*` entries are rv's units.
    static let serviceDirectories: [[String]] = [
        ["Library", "LaunchAgents"],
        [".config", "systemd", "user"],
    ]

    static let binDirectory = [".local", "bin"]

    /// Whether `path` is one of rv's wiring files. `path` is absolute (or
    /// `~`/`$HOME`-prefixed) and lexically normalized; `home` is the home
    /// directory it is judged against. Case-insensitive on Darwin, where
    /// the default APFS volume resolves `~/.CLAUDE` to `~/.claude`.
    public static func matches(_ path: String, home: String) -> Bool {
        guard let relative = homeRelativeComponents(path, home: home) else { return false }
        return matches(relative: relative.map(foldedPathComponent))
    }

    /// Absolute paths of the fixed wiring files under `home`, for callers
    /// that compare a resolved target against a protected file's resolved
    /// location (a dotfiles symlink).
    public static func fixedFiles(home: String) -> [String] {
        homeEntries.map { ([home] + $0).joined(separator: "/") }
    }

    static func matches(relative: [String]) -> Bool {
        let folded = { (parts: [String]) in parts.map(foldedPathComponent) }
        if homeEntries.contains(where: { hasPrefix(relative, folded($0)) }) { return true }
        // Host adapters and plugin dirs: `hooks/rv-guard.py`,
        // `extensions/rv-guard.ts`, `plugins/rv-guard/`, `rv-guard-tui-ask`.
        if relative.contains(where: { $0.hasPrefix("rv-guard") }) { return true }
        for directory in serviceDirectories.map(folded) where hasPrefix(relative, directory) {
            if relative.count > directory.count, relative[directory.count].hasPrefix("dev.rv.") { return true }
        }
        let bin = folded(binDirectory)
        if hasPrefix(relative, bin), relative.count > bin.count {
            return isRVBinaryName(relative[bin.count])
        }
        return false
    }

    /// `rv`, `rvd`, `rv-cli`, every `rv-*` helper, the pack bundle beside
    /// them, and the Swift runtime shim they load.
    static func isRVBinaryName(_ raw: String) -> Bool {
        let name = raw.lowercased()
        return name == "rv" || name == "rvd" || name.hasPrefix("rv-") || name.hasPrefix("rv_")
            || name.contains("_rvpacks.") || name == "libswiftcompatibilityspan.dylib"
    }

    private static func hasPrefix(_ parts: [String], _ prefix: [String]) -> Bool {
        parts.count >= prefix.count && Array(parts.prefix(prefix.count)) == prefix
    }

    /// Components below `home`, or nil when `path` is not under it.
    private static func homeRelativeComponents(_ path: String, home: String) -> [String]? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let first = components.first, first == "~" || first == "$HOME" || first == "${HOME}" {
            return Array(components.dropFirst())
        }
        guard path.hasPrefix("/") else { return nil }
        let homeParts = home.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard homeParts.isEmpty == false, components.count > homeParts.count else { return nil }
        guard zip(components, homeParts).allSatisfy({ foldedPathComponent($0) == foldedPathComponent($1) })
        else { return nil }
        return Array(components.dropFirst(homeParts.count))
    }
}
