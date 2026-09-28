#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Deprecated agent file-grant vocabulary. Agent resolution moved to runtime
/// resource profiles (`RuntimeResourcePolicy`). Kept for one release so
/// external `RVIsolation` library consumers keep compiling; then removed.
@available(*, deprecated, message: "Agent resolution moved to runtime resource profiles.")
public struct AgentBinResolution: Sendable, Equatable {
    /// The agent bin dir itself (PATH lookup).
    public var directory: String
    /// Link and realpath target literals (read + map-executable).
    public var executables: [String]
    /// Support trees (subpath read + map-executable).
    public var trees: [String]
    /// Credential originals (read-data only, never write or map).
    public var credentials: [String]
    /// Agent scratch dirs outside the workspace (subpath read+write).
    /// Same-user scratch data only; the host ensures the roots exist
    /// because the parents stay unwritable.
    public var writableTrees: [String]

    public init(
        directory: String,
        executables: [String] = [],
        trees: [String] = [],
        credentials: [String] = [],
        writableTrees: [String] = []
    ) {
        self.directory = directory
        self.executables = executables
        self.trees = trees
        self.credentials = credentials
        self.writableTrees = writableTrees
    }
}

/// Deprecated agent CLI locator. See `AgentBinResolution`.
@available(*, deprecated, message: "Agent resolution moved to runtime resource profiles.")
public enum AgentBin {
    public static let directoryName = "rv-agent-bin"
    public static let names = ["claude", "codex", "muse", "opencode", "node"]

    /// Sibling of the running host (or CLI) binary, whatever the install
    /// prefix is. Nil when it cannot be determined.
    public static func directory() -> String? {
        let base = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        guard base.path.isEmpty == false else { return nil }
        return directory(executablePath: base.path)
    }

    public static func directory(executablePath: String) -> String {
        (executablePath as NSString).deletingLastPathComponent
            .appending("/" + directoryName)
    }

    /// The bin dir to admit and put on PATH, or nil when the install
    /// predates agent support. Nil keeps both the profile and PATH exactly
    /// as before.
    public static func installedDirectory() -> String? {
        guard let directory = directory() else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }
        return directory
    }

    /// Per-spawn grants. `home` is the host user's home, owner of the
    /// credential files the cage reads (never writes).
    public static func resolve(binDirectory: String, home: String) -> AgentBinResolution {
        var resolution = AgentBinResolution(directory: binDirectory)
        for name in names {
            let link = "\(binDirectory)/\(name)"
            guard FileManager.default.isExecutableFile(atPath: link),
                let target = posixRealpath(link)
            else {
                continue
            }
            resolution.executables.append(link)
            if target != link {
                resolution.executables.append(target)
            }
            switch name {
            case "claude":
                let auth = "\(home)/.claude/.credentials.json"
                if FileManager.default.isReadableFile(atPath: auth) {
                    resolution.credentials.append(auth)
                }
                // Model, gateway routing, and hooks live in settings; without
                // them the CLI falls back to defaults the gateway rejects.
                for settings in ["settings.json", "settings.local.json"] {
                    let config = "\(home)/.claude/\(settings)"
                    if FileManager.default.isReadableFile(atPath: config) {
                        resolution.credentials.append(config)
                    }
                }
                resolution.writableTrees.append(contentsOf: claudeScratchRoots())
            case "codex":
                // codex.js requires its package tree relatively.
                let package = ((target as NSString).deletingLastPathComponent as NSString)
                    .deletingLastPathComponent
                resolution.trees.append(package)
                let auth = "\(home)/.codex/auth.json"
                if FileManager.default.isReadableFile(atPath: auth) {
                    resolution.credentials.append(auth)
                }
                let config = "\(home)/.codex/config.toml"
                if FileManager.default.isReadableFile(atPath: config) {
                    resolution.credentials.append(config)
                }
            case "muse":
                // The launcher reads version metadata and the versioned
                // binary next to itself. Enumerate (bounded) instead of
                // parsing so renames stay admitted.
                let install = (target as NSString).deletingLastPathComponent
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: install)) ?? []
                for entry in entries.prefix(32) {
                    guard entry.hasPrefix("muse-bin-") || entry == ".muse-version"
                        || entry == ".muse-release-info.json"
                    else {
                        continue
                    }
                    resolution.executables.append("\(install)/\(entry)")
                }
                let auth = "\(home)/.config/muse/auth.json"
                if FileManager.default.isReadableFile(atPath: auth) {
                    resolution.credentials.append(auth)
                }
            case "opencode":
                let auth = "\(home)/.local/share/opencode/auth.json"
                if FileManager.default.isReadableFile(atPath: auth) {
                    resolution.credentials.append(auth)
                }
            default:
                break
            }
        }
        return resolution
    }

    /// Claude's hardcoded file-history scratch dir, keyed by uid.
    private static func claudeScratchRoots() -> [String] {
        let uid = getuid()
        return ["/tmp/claude-\(uid)", "/private/tmp/claude-\(uid)"]
    }
}
