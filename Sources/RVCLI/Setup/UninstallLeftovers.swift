#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIsolation
import RVMCP
import RVService

/// What `rv uninstall` leaves of rv's own data, and how to remove it.
/// A plain uninstall keeps the user's records on purpose (a reinstall picks
/// them up); afterwards no rv binary is left to remove them, so the note
/// names every kept path and value and the commands that remove them by
/// hand. Under `--purge` it lists only what could not be removed.
struct UninstallLeftovers: Equatable, Sendable {
    var configDirectory: String
    /// Names left in the config dir, the judge weights excepted
    /// (`keptModelsNote` covers those).
    var configEntries: [String] = []
    /// rv's log, cache and runtime directories still present.
    var otherPaths: [String] = []
    /// Secrets whose value rv stored under `SecretKeychain.service` and
    /// that are still there: all of them after a plain uninstall, or under
    /// `--purge` when it refused the config dir; those a delete failed for
    /// otherwise.
    var storedSecrets: [String] = []
    /// macOS: MCP servers whose OAuth tokens `rv mcp connect` stored in the
    /// Keychain (`MCPOAuthTokenStore.keychainService`) and that are still
    /// there, with the same plain/`--purge` meaning as `storedSecrets`.
    var storedOAuthServers: [String] = []
    /// `--purge` tried the deletes, so `storedSecrets` are the failures.
    /// False when it did not try (secrets.json is behind a config dir it
    /// refused).
    var secretDeletesAttempted = false
    /// Why secrets.json, which names the stored values, could not be read.
    var secretsUnreadable: String? = nil
    /// rv paths uninstall would not enter, each with why
    /// (`SetupRun.purgeRefusal`). Left out of the `rm -rf` line.
    var refusedPaths: [RefusedPath] = []
    /// System files `sudo rv mcp custodian install` wrote. Never removed
    /// here: `sudo rv mcp custodian uninstall` owns them.
    var custodianSystemPaths: [String] = []
    var purged = false

    struct RefusedPath: Equatable, Sendable {
        var path: String
        var reason: String
    }

    /// `--purge` left some of rv's data or a stored value behind.
    var purgeFailed: Bool {
        purged && keptLines.isEmpty == false
    }

    private static var store: String {
        "\(SecretKeychain.storeName) (service \(SecretKeychain.service))"
    }

    /// The config dir is a symlink or sits under one: `--purge` would not
    /// enter it, nor delete the values its secrets.json names.
    private var configRefused: Bool {
        refusedPaths.contains { $0.path == configDirectory }
    }

    private var keptLines: [String] {
        var lines: [String] = []
        if configEntries.isEmpty == false, configRefused == false {
            lines.append(
                DisplayedText.field(configDirectory) + ": "
                    + configEntries.map { DisplayedText.field($0) }.joined(separator: ", "))
        }
        lines += otherPaths.map { DisplayedText.field($0) }
        // A plain uninstall never enters these: it keeps them like the rest,
        // but no by-hand command goes through a link.
        lines += refusedPaths.map { refused in
            let path = DisplayedText.field(refused.path)
            let reason = DisplayedText.field(refused.reason)
            let held = refused.path == configDirectory && configEntries.isEmpty == false
                ? " (" + configEntries.map { DisplayedText.field($0) }.joined(separator: ", ") + ")"
                : ""
            return purged
                ? "\(path): not entered, \(reason)"
                : "\(path): kept\(held); \(reason), so no command here removes it"
        }
        if storedSecrets.isEmpty == false {
            let count = storedSecrets.count == 1 ? "1 secret value" : "\(storedSecrets.count) secret values"
            let lead = purged ? (secretDeletesAttempted ? "could not delete " : "did not delete ") + count : count
            lines.append(
                lead + " rv stored in \(Self.store): "
                    + storedSecrets.map { DisplayedText.field($0) }.joined(separator: ", "))
        }
        if storedOAuthServers.isEmpty == false {
            let count = storedOAuthServers.count == 1
                ? "1 MCP server's OAuth tokens" : "\(storedOAuthServers.count) MCP servers' OAuth tokens"
            let lead = purged ? (secretDeletesAttempted ? "could not delete " : "did not delete ") + count : count
            lines.append(
                lead + " rv stored in the Keychain (service \(MCPOAuthTokenStore.keychainService)): "
                    + storedOAuthServers.map { DisplayedText.field($0) }.joined(separator: ", "))
        }
        if let secretsUnreadable {
            lines.append(
                "the secret values rv stored in \(Self.store); secrets.json, which names them, "
                    + "could not be read: \(secretsUnreadable)")
        }
        return lines
    }

    /// Empty when nothing was kept.
    var note: String {
        var text = ""
        let kept = keptLines
        if kept.isEmpty == false {
            text += purged
                ? "rv uninstall --purge could not remove all of rv's data; still there:\n"
                : "rv uninstall: kept your rv data, so a reinstall picks it up:\n"
            text += kept.map { "  \($0)\n" }.joined()
            let commands = removalCommands
            if purged {
                text += commands.isEmpty ? "" : "rv uninstall: remove the rest by hand:\n"
            } else if commands.isEmpty == false {
                // --purge refuses what is kept for a symlink and cannot find
                // values while secrets.json is unreadable: do not promise it.
                var unreached: [String] = []
                if configRefused {
                    unreached.append("the config directory or its secret values")
                }
                if refusedPaths.contains(where: { $0.path != configDirectory }) {
                    unreached.append("the paths kept for a symlink")
                }
                if secretsUnreadable != nil {
                    unreached.append("the secret values or secrets.json while it cannot be read")
                }
                let scope = unreached.isEmpty
                    ? "all of it"
                    : "the rest (not " + unreached.joined(separator: ", nor ") + ")"
                text += "rv uninstall: to remove \(scope), run rv uninstall --purge instead next time; "
                    + "with rv gone, by hand:\n"
            }
            text += commands.map { "  \($0)\n" }.joined()
        }
        if custodianSystemPaths.isEmpty == false {
            text += "rv uninstall: kept the MCP custodian's system files ("
                + custodianSystemPaths.map { DisplayedText.field($0) }.joined(separator: ", ")
                + "); sudo rv mcp custodian uninstall removes them, run from an installed rv\n"
        }
        return text
    }

    private var removalCommands: [String] {
        var commands: [String] = []
        if storedSecrets.isEmpty == false || secretsUnreadable != nil {
            commands += secretRemovalCommands
        }
        commands += storedOAuthServers.map {
            "security delete-generic-password -s \(MCPOAuthTokenStore.keychainService) -a \(Self.shellQuoted($0))"
        }
        // No `rm -rf` through a link: a refused config dir is named, not removed.
        let paths = (configEntries.isEmpty || configRefused ? [] : [configDirectory]) + otherPaths
        if paths.isEmpty == false {
            commands.append("rm -rf " + paths.map(Self.shellQuoted).joined(separator: " "))
        }
        return commands
    }

    /// One line per value rv stored, scoped to its account, so the commands
    /// delete what `--purge` would and nothing else in the service. Only
    /// when secrets.json cannot be read (the names are unknown) is the
    /// command service-wide. macOS: `security delete-generic-password`
    /// deletes one item per run; Linux: `secret-tool clear` deletes every
    /// item carrying the attributes given.
    private var secretRemovalCommands: [String] {
        #if canImport(Security)
        guard secretsUnreadable == nil else {
            return [
                "security delete-generic-password -s \(SecretKeychain.service)"
                    + "  # deletes one value per run; repeat until none is found",
            ]
        }
        return storedSecrets.map { "security delete-generic-password -s \(SecretKeychain.service) -a \($0)" }
        #else
        guard secretsUnreadable == nil else {
            return [
                "secret-tool clear service \(SecretKeychain.service)"
                    + "  # deletes every item in \(SecretKeychain.service), also any no definition names",
            ]
        }
        return storedSecrets.map { "secret-tool clear service \(SecretKeychain.service) account \($0)" }
        #endif
    }

    /// A path as one shell word.
    static func shellQuoted(_ path: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-+@%:,=")
        if path.isEmpty == false, path.allSatisfy({ safe.contains($0) }) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension SetupRun {
    /// The values rv stored: definitions that read `keychain rv.secrets/<own
    /// name>`, the items `rv secrets remove` deletes. Never an item under
    /// another service, never an external provider's.
    static func rvStoredSecretNames(_ configuration: SecretsConfiguration) -> [String] {
        configuration.secrets.compactMap { secret in
            secret.source == .keychain(service: SecretKeychain.service, account: secret.name) ? secret.name : nil
        }
    }

    /// `--purge`: deletes each value with the delete `rv secrets remove`
    /// uses. Returns the names whose value may still be there.
    static func purgeStoredSecrets(_ names: [String], keychain: SecretKeychainWriter) -> [String] {
        names.filter { keychain.delete(SecretKeychain.service, $0) == false }
    }

    /// macOS: the servers `rv mcp connect` stored OAuth tokens for. Every
    /// save holds the server's lock file, `mcp-oauth/.<server>.lock` in the
    /// config dir, so those files name them.
    static func oauthKeychainServers(configDirectory: String, files: FileOps) -> [String] {
        let directory = configDirectory + "/" + MCPOAuthTokenStore.directoryName
        guard let entries = try? files.fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return entries.compactMap { entry -> String? in
            guard entry.hasPrefix("."), entry.hasSuffix(".lock"), entry.count > ".lock".count + 1 else { return nil }
            return String(entry.dropFirst().dropLast(".lock".count))
        }.sorted()
    }

    /// `--purge`: deletes each server's OAuth tokens from the Keychain.
    /// Returns the servers whose tokens may still be there.
    static func purgeOAuthTokens(_ servers: [String], keychain: SecretKeychainWriter) -> [String] {
        servers.filter { keychain.delete(MCPOAuthTokenStore.keychainService, $0) == false }
    }

    /// rv's directories outside the config dir: rvd's log directory, the MCP
    /// server scratch caches and, on Linux, rvd's runtime socket directory.
    static func ownedDataDirectories(layout: OwnedPaths, env: SetupEnvironment) -> [String] {
        let home = layout.home.rawValue
        // Cut at the last "/" by hand: NSString would collapse a `//` in
        // HOME's spelling, and every target must start with HOME as given
        // so `purgeRefusal` judges it under HOME.
        let log = RVDLogFile.path(home: home)
        var paths = [log.lastIndex(of: "/").map { String(log[..<$0]) } ?? log]
        #if os(macOS)
        paths.append(home + "/Library/Caches/rv-mcp")
        #else
        paths.append(home + "/.cache/rv-mcp")
        #endif
        paths += env.runtimeSocketDirectories
        return paths
    }

    /// Present, counting a dangling symlink.
    static func ownedPathPresent(_ path: String, files: FileOps) -> Bool {
        files.isSymbolicLink(path) || files.fileExists(path)
    }

    /// Removes an rv-owned path. A symlink is unlinked, never followed; a
    /// directory goes with its contents (`removeItem` unlinks symlinks
    /// inside it and does not descend through them). Callers first clear
    /// the directory it sits in with `purgeRefusal`.
    static func removeOwnedPath(_ path: String, files: FileOps) {
        guard ownedPathPresent(path, files: files) else { return }
        try? files.fileManager.removeItem(atPath: path)
    }

    /// `--purge`: empties the config dir except `keep`. The caller has
    /// cleared the directory itself with `purgeRefusal`.
    static func purgeConfigDirectory(_ directory: String, keeping keep: Set<String>, files: FileOps) {
        guard let entries = try? files.fileManager.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries where keep.contains(entry) == false {
            removeOwnedPath(directory + "/" + entry, files: files)
        }
    }

    /// Why purge must not enter or remove the directory `path`, or nil when
    /// it may (a missing path is nil: nothing to remove). `path` must be a
    /// real directory this user owns (lstat: a symlink is refused, not
    /// unlinked), and its parent must resolve to exactly where it should
    /// be: under the real home for a path in HOME, to itself otherwise. So
    /// `ln -s ~/src ~/.local/state` cannot steer purge into `~/src/rv`.
    static func purgeRefusal(_ path: String, home: String, files: FileOps) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT ? nil : "it could not be inspected"
        }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            let target = (try? files.fileManager.destinationOfSymbolicLink(atPath: path)) ?? "an unreadable target"
            return "it is a symlink to \(target)"
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return "it is not a directory" }
        guard info.st_uid == getuid() else { return "it is owned by another user" }
        let parent = (path as NSString).deletingLastPathComponent
        let expected: String?
        // Paths compare as bytes: Swift's `==` and `hasPrefix` treat NFC and
        // NFD spellings of a name as equal, and on Linux they are two paths.
        if path.utf8.starts(with: (home + "/").utf8) {
            // The part below HOME, cut from the same raw string HOME was
            // prefixed onto, so HOME's own spelling (`/home/u/`, `/home//u`)
            // cannot shift it.
            let below = String(decoding: path.utf8.dropFirst(home.utf8.count), as: UTF8.self)
                .split(separator: "/").map(String.init)
            expected = below.contains("..") || below.contains(".")
                ? nil
                : resolvedPath(home).map { $0 + below.dropLast().map { "/" + $0 }.joined() }
        } else {
            expected = parent
        }
        guard let expected, let resolved = resolvedPath(parent), resolved.utf8.elementsEqual(expected.utf8) else {
            return "a folder above it is a symlink or resolves elsewhere: it resolves to "
                + (resolvedPath(path) ?? "an unresolvable path")
        }
        return nil
    }

    /// A runtime socket directory comes from `XDG_RUNTIME_DIR`, which can
    /// name any directory (`$HOME`, `~/src`). rvd puts only its socket in
    /// `<base>/rv`, so one holding anything else is not rvd's to remove.
    /// Call after `purgeRefusal` accepted the path.
    static func runtimeDirectoryRefusal(_ path: String, files: FileOps) -> String? {
        guard ownedPathPresent(path, files: files) else { return nil }
        guard let entries = try? files.fileManager.contentsOfDirectory(atPath: path) else {
            return "it could not be listed"
        }
        let foreign = entries.filter { $0 != UnixSocketPath.socketFileName }.sorted()
        guard foreign.isEmpty == false else { return nil }
        return "it holds files rvd does not put there: "
            + foreign.map { DisplayedText.field($0) }.joined(separator: ", ")
    }

    /// `realpath(3)`; nil when it does not resolve.
    private static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Names left in the config dir, the judge weights excepted.
    static func keptConfigEntries(layout: OwnedPaths, files: FileOps) -> [String] {
        guard files.isDirectory(layout.configDirectory),
              let entries = try? files.fileManager.contentsOfDirectory(atPath: layout.configDirectory)
        else { return [] }
        let models = (layout.modelsDirectory as NSString).lastPathComponent
        return entries.filter { $0 != models }.sorted()
    }
}
