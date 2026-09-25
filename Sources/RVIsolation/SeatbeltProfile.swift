#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// Darwin syscalls that can leave the process group RV owns.
///
/// `setpgid` and `setsid` stay denied: a group member must not reassign
/// itself. `posix_spawn` stays allowed: Node, Python, and Rust spawn only
/// through it, and agents cannot work without it. Spawned children inherit
/// this same profile, so group escape buys no file or network authority,
/// and forced detach reaps anything left on the volume.
enum SeatbeltLifetimeSyscall {
    static let setpgid = 82
    static let setsid = 147
}

/// SBPL text compiled from a contained `IsolationPlan`. Production construction
/// is `compileSeatbeltProfile` only.
public struct SeatbeltProfile: Sendable, Equatable {
    public let source: String
    public let workspacePath: String

    init(source: String, workspacePath: String) {
        self.source = source
        self.workspacePath = workspacePath
    }

    /// Loopback TCP only. The cage reaches the host-side egress proxy and
    /// local gateways/MCP servers on loopback; every non-loopback connect
    /// stays denied. Seatbelt only filters the remote host as `*` or
    /// `localhost`, so per-host direct egress is unrepresentable and all
    /// external traffic funnels through the proxy allowlist instead.
    func allowingLoopbackEgress() -> SeatbeltProfile {
        let addition = """

        (allow network-outbound
            (remote tcp "localhost:*"))
        """
        return SeatbeltProfile(source: source + addition, workspacePath: workspacePath)
    }

    /// Real agent CLIs for a contained shell.
    ///
    /// The agent bin dir (sibling of the host binary) holds symlinks to the
    /// installed agent executables and sits on the contained PATH. Each
    /// resolution grants exactly the resolved link, its target, its support
    /// tree, and its credential file (read-only): agents execute under this
    /// same contained profile, and missing agents simply resolve to nothing.
    func allowingAgentBin(_ resolution: AgentBinResolution) -> SeatbeltProfile {
        var additions = ""
        let reads = [resolution.directory] + resolution.executables
        if reads.isEmpty == false {
            let literals = reads
                .map { "(literal \"\(escapeSeatbeltSubpath($0))\")" }
                .joined(separator: "\n        ")
            additions += """

            (allow file-read* file-map-executable
                \(literals))
            """
        }
        for tree in resolution.trees {
            additions += """

            (allow file-read* file-map-executable
                (subpath "\(escapeSeatbeltSubpath(tree))"))
            """
        }
        if resolution.credentials.isEmpty == false {
            let literals = resolution.credentials
                .map { "(literal \"\(escapeSeatbeltSubpath($0))\")" }
                .joined(separator: "\n        ")
            additions += """

            (allow file-read-data
                \(literals))
            """
        }
        for tree in resolution.writableTrees {
            additions += """

            (allow file-read* file-write*
                (subpath "\(escapeSeatbeltSubpath(tree))"))
            """
        }
        return SeatbeltProfile(source: source + additions, workspacePath: workspacePath)
    }

    /// The granted executable may live outside the workspace. Allow reading
    /// and mapping that one file, including its realpath when the caller path
    /// and the kernel path differ (`/var` versus `/private/var`). This does
    /// not allow neighboring files.
    func allowingExecutable(_ executable: String) -> SeatbeltProfile {
        var paths = [executable]
        if let resolved = posixRealpath(executable), resolved != executable {
            paths.append(resolved)
        }
        let literals = paths.map { "(literal \"\(escapeSeatbeltSubpath($0))\")" }
            .joined(separator: "\n        ")
        let addition = """

        (allow file-read* file-map-executable
            \(literals))
        """
        return SeatbeltProfile(source: source + addition, workspacePath: workspacePath)
    }
}

/// Resolved agent file grants for one contained spawn.
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

/// Host-staged agent credential links, shared by staging and publish scrub.
///
/// The cage home is the workspace, so agents look for credentials at these
/// workspace-relative paths. The host symlinks the host-owned originals
/// into place before each spawn; publish removes exactly these links (plus
/// the cage dir) when the snapshot does not own them, so user-owned files
/// at the same paths are never touched.
///
/// Lives in this unguarded file (not the macOS-only supervisor) because the
/// profile builder resolves it on every platform. The contents are portable:
/// string constants plus a getuid-keyed scratch path.
enum AgentHomeStaging {
    static let cageDirectoryName = ".rv-cage"
    static let cageTmpSubpath = ".rv-cage/tmp"
    /// Workspace-relative link path to home-relative credential source.
    static let credentialLinks = [
        (relative: ".codex/auth.json", source: ".codex/auth.json"),
        (relative: ".codex/config.toml", source: ".codex/config.toml"),
        (relative: ".config/muse/auth.json", source: ".config/muse/auth.json"),
        (relative: ".claude/.credentials.json", source: ".claude/.credentials.json"),
        (relative: ".claude/settings.json", source: ".claude/settings.json"),
        (relative: ".claude/settings.local.json", source: ".claude/settings.local.json"),
        (relative: ".local/share/opencode/auth.json", source: ".local/share/opencode/auth.json"),
    ]
    /// Claude's hardcoded file-history scratch dir, keyed by uid. It ignores
    /// TMPDIR for this path, so the host ensures the root exists and the
    /// profile admits the subpath (same-user scratch data only, never code).
    static func claudeScratchRoots() -> [String] {
        let uid = getuid()
        return ["/tmp/claude-\(uid)", "/private/tmp/claude-\(uid)"]
    }
    /// Gateway routing passes through so agents use the host's model
    /// gateway instead of direct provider endpoints.
    static let gatewayPassthrough = [
        "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
    ]
    /// Provider keys that pass through when set on the host. muse keeps
    /// its token in the host keychain (unreachable in the cage) and honors
    /// only META_API_KEY otherwise. claude gates on login state bound to
    /// the passwd home, which a workspace HOME can never satisfy; a key
    /// selects key auth and skips the gate. Other provider keys stay
    /// blocked: codex and opencode authenticate from staged files.
    static let apiKeyPassthrough = [
        "META_API_KEY",
        "ANTHROPIC_API_KEY",
    ]
    /// Non-secret stand-in so gateway-routed claude runs work with no host
    /// key configured. The gateway performs real auth and ignores the
    /// value; direct-endpoint runs with it fail closed at the provider
    /// (401), same as having no key.
    static let anthropicGatewayPlaceholder = "rv-cage-gateway-placeholder"
}

/// Locates installed agent CLIs and resolves their file grants.
///
/// The bin dir is a sibling of the running host (or CLI) binary holding one
/// symlink per agent. Resolution runs host-side per spawn: only links that
/// resolve to an executable file grant anything, so a partially installed
/// agent set degrades to command-not-found per agent instead of failing.
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
                resolution.writableTrees.append(
                    contentsOf: AgentHomeStaging.claudeScratchRoots()
                )
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
}

/// Seatbelt profile for a workspace-scoped contained plan.
/// `(deny default)` plus the execution baseline and the loopback egress
/// rule. Observed / mediated plans are not applicable. A contained plan with
/// any broader filesystem, network, or process guarantee is rejected.
public func compileSeatbeltProfile(
    _ plan: IsolationPlan
) -> Result<SeatbeltProfile, IsolationApplyError> {
    switch plan.mode {
    case .observed, .mediated:
        return .failure(.profileNotApplicable)
    case .contained(let guarantees):
        guard let workspace = plan.workspace else {
            return .failure(.containedGuaranteesUnsupported)
        }
        switch guarantees.filesystem {
        case .workspaceScoped(let limitedTo):
            guard limitedTo == workspace else {
                return .failure(.containedGuaranteesUnsupported)
            }
        case .unrestricted:
            return .failure(.containedGuaranteesUnsupported)
        }
        switch guarantees.network {
        case .denied:
            break
        case .unrestricted:
            return .failure(.containedGuaranteesUnsupported)
        }
        switch guarantees.process {
        case .hostSignalsDenied:
            break
        case .unrestricted:
            return .failure(.containedGuaranteesUnsupported)
        }
        switch guarantees.descent {
        case .inherited:
            break
        case .notInherited:
            return .failure(.containedGuaranteesUnsupported)
        }
        return compileFirstSliceProfile(workspace: workspace)
    }
}

/// Kernel path for Seatbelt `subpath`. `URL.resolvingSymlinksInPath()` on
/// current Darwin keeps `/var` and can rewrite `/private/tmp` back to `/tmp`,
/// which does not match sandbox-exec. POSIX `realpath` does (`/tmp` →
/// `/private/tmp`). Nonexistent compile fixtures fall back to the URL path.
/// Prepare / spawn never use this fallback: an existing directory that
/// `realpath` cannot resolve is `workspacePathUnresolvable`.
func resolvedWorkspacePath(_ workspace: WorkingDirectory) -> String {
    posixRealpath(workspace.rawValue)
        ?? URL(fileURLWithPath: workspace.rawValue).resolvingSymlinksInPath().path
}

func existingResolvedWorkspacePath(
    _ workspace: WorkingDirectory
) -> Result<String, IsolationApplyError> {
    if let resolved = posixRealpath(workspace.rawValue) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            return .failure(.workspaceDoesNotExist)
        }
        if isUnsafeResolvedWorkspace(resolved) {
            return .failure(.workspacePathUnsafe)
        }
        return .success(resolved)
    }
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
        atPath: workspace.rawValue,
        isDirectory: &isDirectory
    )
    if exists, isDirectory.boolValue {
        return .failure(.workspacePathUnresolvable)
    }
    return .failure(.workspaceDoesNotExist)
}

func posixRealpath(_ path: String) -> String? {
    path.withCString { source in
        guard let buffer = realpath(source, nil) else {
            return nil
        }
        defer { free(buffer) }
        return String(cString: buffer)
    }
}

func compileFirstSliceProfile(
    workspace: WorkingDirectory
) -> Result<SeatbeltProfile, IsolationApplyError> {
    let raw = workspace.rawValue
    guard raw.hasPrefix("/") else {
        return .failure(.workspaceMustBeAbsolute)
    }
    if raw.contains("\n") || raw.contains("\0") {
        return .failure(.workspacePathUnsafe)
    }
    let resolved = resolvedWorkspacePath(workspace)
    if resolved.isEmpty {
        return .failure(.workspacePathUnresolvable)
    }
    if isUnsafeResolvedWorkspace(resolved) {
        return .failure(.workspacePathUnsafe)
    }
    let escaped = escapeSeatbeltSubpath(resolved)
    // `file-read-data` of `/` is the root directory inode, not every file.
    // Metadata on the walk prefixes lets tools resolve paths. Content outside
    // the workspace and the system prefixes below stays denied.
    // `mach-lookup` is an unfiltered baseline; it is not a grant of host files.
    // `file-write*` does not include `file-link` or `file-clone` on this OS.
    // Deny them explicitly so a later wildcard change cannot create aliases.
    // Path rules still cannot see a hard link planted by another process.
    // `WorkspaceInodeBoundary` mounts a separate volume before spawn.
    let source = """
    (version 1)
    (deny default)
    (allow process-exec*)
    (allow process-fork)
    ;; In-sandbox signals only. TTY signals arrive from the unsandboxed host
    ;; writing the PTY. An untargeted signal allow would let the agent signal
    ;; processes outside this sandbox.
    (allow signal (target same-sandbox))
    (allow sysctl-read)
    (allow mach-lookup)
    (allow file-read-data (literal "/"))
    (allow file-read-metadata
        (subpath "/private")
        (subpath "/tmp")
        (subpath "/var")
        (subpath "/Users"))
    ;; System config lookups must report missing, not denied: tools tell
    ;; ENOENT (fall back) from EPERM (fatal). Metadata only: no content,
    ;; no directory listing.
    (allow file-read-metadata
        (literal "/etc")
        (literal "/etc/codex"))
    ;; Exception: TLS trust is fatal-if-missing (no fallback), so the CA
    ;; bundle and OpenSSL config read as content. Root-owned public data;
    ;; the cage user cannot write here.
    (allow file-read*
        (subpath "/etc/ssl")
        (subpath "/private/etc/ssl"))
    ;; Exception: timezone data is fatal-if-denied. /etc/localtime points
    ;; into /var/db/timezone/zoneinfo, and JS runtimes (Bun, Node) trap on
    ;; EPERM reading it instead of falling back. Root-owned public data;
    ;; the cage user cannot write here.
    (allow file-read*
        (subpath "/var/db/timezone")
        (subpath "/private/var/db/timezone"))
    (allow file-map-executable file-read* file-ioctl
        (subpath "/usr")
        (subpath "/bin")
        (subpath "/System")
        (subpath "/Library")
        (subpath "/dev")
        (subpath "\(escaped)"))
    (allow file-write*
        (subpath "\(escaped)"))
    (deny file-link)
    (deny file-clone)
    (deny syscall-unix (syscall-number \(SeatbeltLifetimeSyscall.setpgid)))
    (deny syscall-unix (syscall-number \(SeatbeltLifetimeSyscall.setsid)))
    ;; `posix_spawn` stays allowed: the runtimes agents are built on spawn
    ;; only through it. Children inherit this profile (descent), so spawn
    ;; grants no file or network authority beyond this fence.
    ;; `/dev/null` is the universal sink. Scripts and runtimes redirect
    ;; there; write-data on this one literal cannot exfiltrate or persist.
    (allow file-write-data
        (literal "/dev/null"))
    """
    return .success(SeatbeltProfile(source: source, workspacePath: resolved))
}

/// POSIX `/` as the write root applies the first-slice limit to the entire
/// tree (Landlock `PATH_BENEATH /`, Seatbelt `subpath "/"`).
func isFilesystemRoot(_ path: String) -> Bool {
    path == "/"
}

func isUnsafeResolvedWorkspace(_ path: String) -> Bool {
    path.contains("\n") || path.contains("\0") || isFilesystemRoot(path)
}

func isResolvedPath(_ path: String, atOrBeneath ancestor: String) -> Bool {
    if path == ancestor {
        return true
    }
    let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
    return path.hasPrefix(prefix)
}

func escapeSeatbeltSubpath(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}
