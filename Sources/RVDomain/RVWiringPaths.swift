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
///
/// Host settings files that can disable or override hooks
/// (`isHostSettingsFile`) are protected at every scope, project and local
/// included, whether or not rv is wired into them yet.
public enum RVWiringPaths {
    public static let pattern = "rv-wiring"
    public static let ruleID = RuleID(pack: .coreSecrets, pattern: pattern)
    public static let reason =
        "rv's hook, service and binary files can only be changed by you, outside the agent."

    /// Home-relative files and directories (the path itself or anything
    /// under it): hook registrations, then the exact adapter locations
    /// `rv setup` writes.
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
        [".claude", "hooks", "rv-guard.py"],
        [".codex", "hooks", "rv-guard.py"],
        [".cursor", "hooks", "rv-guard.py"],
        [".gemini", "config", "hooks", "rv-guard.py"],
        [".pi", "agent", "extensions", "rv-guard.ts"],
        [".config", "opencode", "plugins", "rv-guard.js"],
        [".config", "opencode", "plugins", "rv-guard-tui.js"],
        [".config", "opencode", "rv-guard-tui-ask"],
        [".openclaw", "extensions", "rv-guard"],
        [".hermes", "plugins", "rv-guard"],
        // systemd's user manager reads these into every user service's
        // environment, rvd included: an `LD_PRELOAD=` line here runs agent
        // code inside rvd at the next login.
        [".config", "environment.d"],
        // The same for systemd itself: `DefaultEnvironment=` in the user
        // manager's config, and drop-ins under `service.d` that apply to
        // every user service (`Environment=`, a replaced `ExecStart=`).
        [".config", "systemd", "user.conf"],
        [".config", "systemd", "user.conf.d"],
        [".config", "systemd", "user", "service.d"],
    ]

    /// Home-relative directories whose `dev.rv.*` entries are rv's units.
    static let serviceDirectories: [[String]] = [
        ["Library", "LaunchAgents"],
        [".config", "systemd", "user"],
        // `systemctl --user enable` links rvd's unit here; removing the link
        // silently stops rvd from starting at login.
        [".config", "systemd", "user", "default.target.wants"],
    ]

    static let binDirectory = [".local", "bin"]

    /// Host settings files (any scope) that can carry a hook registration
    /// or a key that disables hooks (`disableAllHooks`, a Codex feature
    /// flag, a Cursor/Gemini hooks block).
    static let hostSettingsShapes: [[String]] = [
        [".claude", "settings.json"],
        [".claude", "settings.local.json"],
        [".codex", "hooks.json"],
        [".codex", "config.toml"],
        [".cursor", "hooks.json"],
        [".gemini", "settings.json"],
        [".gemini", "config", "hooks.json"],
    ]

    /// Whether `path` is one of rv's wiring files. `path` is absolute (or
    /// `~`/`$HOME`-prefixed) and lexically normalized; `home` is the home
    /// directory it is judged against. Case-insensitive on Darwin, where
    /// the default APFS volume resolves `~/.CLAUDE` to `~/.claude`.
    public static func matches(_ path: String, home: String) -> Bool {
        guard let relative = homeRelativeComponents(path, home: home) else { return false }
        return matches(relative: relative.map(foldedPathComponent))
    }

    /// Whether `path` is a proper ancestor (below home) of a wiring entry,
    /// or a wiring service / bin directory itself: moving, deleting or
    /// chmod-ing it unhooks rv as surely as editing the file inside.
    public static func matchesAncestor(_ path: String, home: String) -> Bool {
        guard let relative = homeRelativeComponents(path, home: home)?.map(foldedPathComponent),
              relative.isEmpty == false
        else { return false }
        let folded = { (parts: [String]) in parts.map(foldedPathComponent) }
        let properAncestors = homeEntries.map(folded).contains { entry in
            relative.count < entry.count && hasPrefix(entry, relative)
        }
        let directories = (serviceDirectories + [binDirectory]).map(folded).contains { directory in
            relative.count <= directory.count && hasPrefix(directory, relative)
        }
        return properAncestors || directories
    }

    /// Whether `path` (any spelling, any directory) ends in a host settings
    /// file shape (`hostSettingsShapes`).
    public static func isHostSettingsFile(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
            .map { foldedPathComponent(String($0)) }
        return hostSettingsShapes.contains { shape in
            let folded = shape.map(foldedPathComponent)
            return components.count >= folded.count && Array(components.suffix(folded.count)) == folded
        }
    }

    /// Absolute paths of the fixed wiring files under `home`, for callers
    /// that compare a resolved target against a protected file's resolved
    /// location (a dotfiles symlink) or its inode (a hard link).
    public static func fixedFiles(home: String) -> [String] {
        let units = ["evaluate", "mcp-custodian", "audit-forward"].map { "Library/LaunchAgents/dev.rv.\($0).plist" }
        let extra = [
            ".local/bin/rv", ".local/bin/rv-cli", ".local/bin/rvd",
            ".config/systemd/user/dev.rv.evaluate.service",
            ".openclaw/extensions/rv-guard/index.js",
            ".hermes/plugins/rv-guard/__init__.py", ".hermes/plugins/rv-guard/plugin.yaml",
        ] + units
        return homeEntries.map { ([home] + $0).joined(separator: "/") } + extra.map { home + "/" + $0 }
    }

    /// Whether the existing regular file at `path` is a hard link to one
    /// of the fixed wiring files (same device and inode). Only a file with
    /// more than one link is compared.
    public static func sharesInodeWithWiring(_ path: String, home: String) -> Bool {
        wiringFileSharingInode(path, home: home) != nil
    }

    /// The fixed wiring file `path` is a hard link to, if any.
    public static func wiringFileSharingInode(_ path: String, home: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink > 1 else { return nil }
        return fixedFiles(home: home).first { file in
            var other = stat()
            return stat(file, &other) == 0 && other.st_dev == info.st_dev && other.st_ino == info.st_ino
        }
    }

    static func matches(relative: [String]) -> Bool {
        let folded = { (parts: [String]) in parts.map(foldedPathComponent) }
        if homeEntries.contains(where: { hasPrefix(relative, folded($0)) }) { return true }
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
    /// them, install.sh's `.rv*` temporaries and runtime-library list, and
    /// the shared libraries they load: the macOS Swift shim and, on Linux,
    /// the Swift runtime (`libswiftCore.so`, `libFoundation.so`, ...) that
    /// rv-cli and rvd load from `$ORIGIN`. A replaced runtime library runs
    /// inside rvd on its next start, so the file-tool door must refuse it
    /// exactly as the shell guard (`RVInstallPathGuard`) already does.
    static func isRVBinaryName(_ raw: String) -> Bool {
        let name = raw.lowercased()
        return name == "rv" || name == "rvd" || name.hasPrefix("rv-") || name.hasPrefix("rv_")
            || name.hasPrefix(".rv") || name.contains("_rvpacks.")
            || name.hasSuffix(".dylib") || name.hasSuffix(".so") || name.contains(".so.")
    }

    private static func hasPrefix(_ parts: [String], _ prefix: [String]) -> Bool {
        parts.count >= prefix.count && Array(parts.prefix(prefix.count)) == prefix
    }

    /// Components below `home`, or nil when `path` is not under it. `~user`
    /// spellings expand through the user database.
    private static func homeRelativeComponents(_ path: String, home: String) -> [String]? {
        if case .expanded(let expanded) = expandTildeUser(path) {
            return homeRelativeComponents(expanded, home: home)
        }
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
