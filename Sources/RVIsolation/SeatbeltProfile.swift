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

/// Mach/XPC boundary for contained runtimes.
///
/// Denied by default. Narrow allows appear in `allowedServices` only when a
/// normal development workflow demonstrably requires the service and the
/// service is not credential-bearing. XPC to launchd services is mediated
/// through mach-lookup, so denying mach-lookup also blocks XPC to securityd
/// and other host agents.
enum SeatbeltMachPolicy {
    /// Mach services the cage may look up, by exact global name. As of the
    /// Mach/XPC hardening chunk this holds exactly one entry
    /// (`com.apple.bsd.dirhelper`), proven necessary for SwiftPM linking;
    /// shell, git, swiftc, clang, python, node, curl (loopback and proxied
    /// HTTPS), PTY, and subprocess spawning were all verified working with
    /// zero allows. Other denied lookups (logd, notification_center,
    /// opendirectoryd, cfprefsd, trustd, securityd.xpc, SecurityServer,
    /// pasteboard, and others) are non-fatal fallbacks for these tools.
    ///
    /// Each future entry must name the exact `global-name` and carry a
    /// comment explaining which workflow requires it and why the service is
    /// safe. Never add broad classes (security services, pasteboard,
    /// notifications, launchservices, user agents, credential stores)
    /// without a demonstrated workflow need.
    ///
    /// macOS version compatibility: service names are stable across recent
    /// releases, but if a required service is renamed on a new OS, list both
    /// spellings explicitly with version comments rather than using a
    /// wildcard or prefix match. SBPL `global-name` takes exact strings;
    /// there is no safe wildcard for Mach names.
    static let allowedServices: [String] = [
        // SwiftPM link requires BSD dirhelper: `swift build` fails at the
        // `Ld` phase with SwiftBuild `permissionDenied` without it and
        // succeeds with only this entry allowed (verified: empty allowlist
        // fails, dirhelper-only succeeds, Keychain stays blocked with
        // SecItem returning -50). Compile, git, clang, python, node, curl,
        // and subprocess spawning need no Mach service. Dirhelper performs
        // BSD directory operations (temporary directory setup) and holds no
        // credentials; the file sandbox still constrains every cage write,
        // so this grants no file authority beyond the existing profile.
        "com.apple.bsd.dirhelper",
    ]

    /// SBPL fragment for the Mach boundary. Explicit `(deny mach-lookup)`
    /// and `(deny mach-register)` state the default (redundant with `(deny
    /// default)` but visible in review); narrow allows follow so last-match
    /// grants only the listed names.
    static func sbplRules() -> String {
        var rules = """
        ;; Mach/XPC denied by default. The cage must not reach host
        ;; credential/security services (securityd, SecurityServer, trustd,
        ;; biometrickitd, GSSCred, pasteboard, accounts, SSO) or arbitrary
        ;; host agents. Narrow allows in SeatbeltMachPolicy.allowedServices
        ;; only, each with a workflow justification.
        (deny mach-lookup)
        (deny mach-register)
        """
        if allowedServices.isEmpty == false {
            let names = allowedServices
                .map { "(global-name \"\($0)\")" }
                .joined(separator: "\n    ")
            rules += """

            (allow mach-lookup
                \(names))
            """
        }
        return rules
    }
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
    /// external traffic funnels through the proxy policy instead.
    func allowingLoopbackEgress() -> SeatbeltProfile {
        let addition = """

        (allow network-outbound
            (remote tcp "localhost:*"))
        """
        return SeatbeltProfile(source: source + addition, workspacePath: workspacePath)
    }

    /// Loopback servers. The cage may bind and accept on loopback for local
    /// dev servers and test fixtures; the loopback interface is host-wide,
    /// so a port collision with another workspace or host process fails
    /// safe at bind time. No inbound or bind rule exists for any other
    /// interface.
    func allowingLoopbackBind() -> SeatbeltProfile {
        let addition = """

        (allow network-bind
            (local tcp "localhost:*"))
        (allow network-inbound
            (remote tcp "localhost:*"))
        """
        return SeatbeltProfile(source: source + addition, workspacePath: workspacePath)
    }

    /// Productive workspace grants: the RV-managed home/cache/tmp roots
    /// (read/write/execute), toolchain and PATH-implied trees
    /// (read/execute), developer-configuration reads, and explicit denies
    /// for sensitive paths that take precedence over every allow.
    func allowingProductiveWorkspace(_ resolution: ProductiveWorkspaceResolution) -> SeatbeltProfile {
        var additions = ""
        if let home = resolution.developerHome {
            additions += """

            (allow file-read* file-write* file-map-executable file-ioctl
                (subpath "\(escapeSeatbeltSubpath(home.home))")
                (subpath "\(escapeSeatbeltSubpath(home.cache))")
                (subpath "\(escapeSeatbeltSubpath(home.tmp))"))
            """
        }
        let reads = resolution.pathDirectories + resolution.toolchainTrees
        if reads.isEmpty == false {
            let literals = reads
                .map { "(subpath \"\(escapeSeatbeltSubpath($0))\")" }
                .joined(separator: "\n        ")
            additions += """

            (allow file-read* file-map-executable
                \(literals))
            """
        }
        if resolution.walkMetadataRoots.isEmpty == false {
            let literals = resolution.walkMetadataRoots
                .map { "(subpath \"\(escapeSeatbeltSubpath($0))\")" }
                .joined(separator: "\n        ")
            additions += """

            (allow file-read-metadata
                \(literals))
            """
        }
        // Developer-directory resolution must agree with the host:
        // `xcode-select -p` and `xcrun` read this link, and falling back to
        // the wrong toolchain breaks every Apple compiler invocation. The
        // hosts file lets `localhost` resolve without a network round trip.
        // Both spellings are granted because `/etc` and `/var` are
        // symlinks: the kernel evaluates the `/private` path. All are
        // root-owned public configuration.
        additions += """

        (allow file-read*
            (literal "/var/db/xcode_select_link")
            (literal "/private/var/db/xcode_select_link")
            (literal "/etc/hosts")
            (literal "/private/etc/hosts"))
        """
        if resolution.sensitiveDenies.isEmpty == false {
            let literals = resolution.sensitiveDenies
                .map { "(subpath \"\(escapeSeatbeltSubpath($0))\")" }
                .joined(separator: "\n        ")
            additions += """

            (deny file-read*
                \(literals))
            """
        }
        if resolution.sensitiveFileDenies.isEmpty == false {
            let literals = resolution.sensitiveFileDenies
                .map { "(literal \"\(escapeSeatbeltSubpath($0))\")" }
                .joined(separator: "\n        ")
            additions += """

            (deny file-read*
                \(literals))
            """
        }
        // Fallback temp for tools whose tasks do not inherit TMPDIR.
        // SwiftBuild backend tasks run with a constructed environment (PATH
        // plus settings) that drops TMPDIR/TEMP/TMP, so the Swift driver
        // falls back to the confstr per-user temp dir: link temp files
        // need it writable (`permissionDenied` without), and test-bundle
        // plist processing creates temp dirs there with backup exclusion,
        // which needs read-back too. This opens same-user transient temp
        // files to the cage; macOS itself isolates those per-user only
        // (every process the user runs can already read them), and the
        // persistent secrets (home, keychains, caches, the catalog above)
        // stay denied. Upstream: SwiftPM should propagate the temp vars
        // to SwiftBuild tasks; narrow or remove this grant when it does.
        if let systemTmp = resolution.systemTemporaryDirectory {
            additions += """

            (allow file-read* file-write*
                (subpath "\(escapeSeatbeltSubpath(systemTmp))"))
            """
        }
        return SeatbeltProfile(source: source + additions, workspacePath: workspacePath)
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

/// Resolved productive-workspace grants for one contained spawn.
public struct ProductiveWorkspaceResolution: Sendable, Equatable {
    /// RV-managed home, or nil when it cannot be prepared (legacy
    /// workspace-home fallback).
    public var developerHome: WorkspaceDeveloperHome?
    /// Sanitized cage `PATH` value.
    public var pathValue: String
    /// Admitted PATH directories (realpaths) for read/execute grants.
    public var pathDirectories: [String]
    /// Toolchain trees (system roots, home-state roots, PATH-implied
    /// parents) for read/execute grants.
    public var toolchainTrees: [String]
    /// Sensitive subpaths for explicit deny rules.
    public var sensitiveDenies: [String]
    /// Sensitive files for explicit deny rules.
    public var sensitiveFileDenies: [String]
    /// Top-level walk roots needing traversal metadata for the grants
    /// above (e.g. `/opt` for `/opt/homebrew`). The base profile already
    /// covers the system roots; without these, `realpath` fails with
    /// EPERM on every granted path beneath them.
    public var walkMetadataRoots: [String]
    /// Host confstr per-user temp dir, or nil when it cannot be resolved.
    /// SwiftBuild backend tasks run with a constructed environment that
    /// drops TMPDIR/TEMP/TMP, so the Swift driver falls back here for link
    /// temp files and test-bundle plist processing falls back here for
    /// temp dirs. The profile grants it read-write (see below); nil omits
    /// the grant and Swift builds keep failing as before.
    public var systemTemporaryDirectory: String?

    public init(
        developerHome: WorkspaceDeveloperHome? = nil,
        pathValue: String = "/usr/bin:/bin",
        pathDirectories: [String] = [],
        toolchainTrees: [String] = [],
        sensitiveDenies: [String] = [],
        sensitiveFileDenies: [String] = [],
        walkMetadataRoots: [String] = [],
        systemTemporaryDirectory: String? = nil
    ) {
        self.developerHome = developerHome
        self.pathValue = pathValue
        self.pathDirectories = pathDirectories
        self.toolchainTrees = toolchainTrees
        self.sensitiveDenies = sensitiveDenies
        self.sensitiveFileDenies = sensitiveFileDenies
        self.walkMetadataRoots = walkMetadataRoots
        self.systemTemporaryDirectory = systemTemporaryDirectory
    }
}

/// First path components whose metadata the base profile already grants,
/// so productive grants beneath them need no extra walk rule. `etc` stays
/// excluded deliberately: nothing granted should live beneath it, and the
/// base profile keeps `/etc` an existence oracle with content denied.
private let productiveWalkCoveredRoots: Set<String> = [
    "usr", "bin", "sbin", "System", "Library", "dev", "private", "tmp", "var", "Users", "etc",
]

/// Top-level directories (`/opt`, `/Applications`, …) that need a
/// metadata-only walk rule for `paths` to be traversable and
/// canonicalizable. Deterministic order.
func productiveWalkMetadataRoots(paths: [String]) -> [String] {
    var roots: [String] = []
    for path in paths {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = parts.first.map(String.init),
            productiveWalkCoveredRoots.contains(first) == false
        else {
            continue
        }
        let root = "/\(first)"
        if roots.contains(root) == false {
            roots.append(root)
        }
    }
    return roots.sorted()
}

/// Resolve the productive-workspace context for a spawn, host-side.
///
/// Pure function of the workspace path and host environment (plus
/// existence probes), so the profile compiler and the environment builder
/// compute the same facts independently. Side effects (`ensure`) are
/// idempotent. Degrades gracefully: without a usable host home there is no
/// RV-managed home and no host PATH inheritance, only the legacy minimal
/// environment.
public func resolveProductiveWorkspace(
    workspacePath: String,
    hostEnvironment: [String: String]? = nil,
    agentBin: String? = nil
) -> ProductiveWorkspaceResolution {
    let host = hostEnvironment ?? ProcessInfo.processInfo.environment
    guard let hostHome = host["HOME"], isUsableAbsolutePath(hostHome) else {
        return ProductiveWorkspaceResolution()
    }
    var developerHome: WorkspaceDeveloperHome?
    if isUsableAbsolutePath(workspacePath),
        let resolved = WorkspaceDeveloperHome.resolve(workspacePath: workspacePath, hostHome: hostHome),
        resolved.ensure(hostHome: hostHome)
    {
        developerHome = resolved
    }
    let sanitized = ContainedPATH.sanitize(
        hostPATH: host["PATH"],
        hostHome: hostHome,
        agentBin: agentBin,
        rvBin: developerHome?.bin
    )
    var trees = ContainedToolchainRoots.existingSystemRoots()
    trees.append(contentsOf: ContainedToolchainRoots.existingHomeStateRoots(hostHome: hostHome))
    trees.append(contentsOf: sanitized.impliedDirectories)
    var seen = Set<String>()
    let toolchainTrees = trees.filter { seen.insert($0).inserted }
    var walkPaths = sanitized.directories + toolchainTrees
    if let developerHome {
        walkPaths.append(contentsOf: [developerHome.home, developerHome.cache, developerHome.tmp])
    }
    return ProductiveWorkspaceResolution(
        developerHome: developerHome,
        pathValue: sanitized.value,
        pathDirectories: sanitized.directories,
        toolchainTrees: toolchainTrees,
        sensitiveDenies: ContainedSensitivePaths.denyPaths(hostHome: hostHome, excluding: []),
        sensitiveFileDenies: sanitized.sensitiveFiles,
        walkMetadataRoots: productiveWalkMetadataRoots(paths: walkPaths),
        systemTemporaryDirectory: productiveSystemTemporaryDirectory()
    )
}

/// Host confstr per-user temp dir for the write-only fallback grant.
/// confstr is authoritative (it does not read `$TMPDIR`, so a hostile or
/// odd host value cannot redirect the grant). Nil when unresolvable,
/// unusable, or missing; the caller then omits the grant.
func productiveSystemTemporaryDirectory() -> String? {
    #if os(macOS)
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 1 else { return nil }
        var path = String(cString: buffer)
        while path.hasSuffix("/"), path.count > 1 {
            path.removeLast()
        }
        guard isUsableAbsolutePath(path) else { return nil }
        // The kernel evaluates symlinks before Seatbelt matching, so grant
        // the canonical spelling (`/private/var/...`, never `/var/...`).
        guard let canonical = posixRealpath(path), isUsableAbsolutePath(canonical) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }
        return canonical
    #else
        return nil
    #endif
}

/// Host-staged agent credential links, shared by staging and publish scrub.
///
/// The cage home is the RV-managed developer home, so agents look for
/// credentials at these home-relative paths. The host symlinks the
/// host-owned originals into place before each spawn. Legacy links staged
/// into the workspace by older RV versions are still scrubbed at publish:
/// publish removes exactly these relative paths (plus the legacy cage dir)
/// when the snapshot does not own them, so user-owned files at the same
/// paths are never touched.
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

/// Host-side agent home staging, run before each contained spawn.
///
/// Symlinks the host-owned credential originals into the RV-managed cage
/// home (read-only targets; the profile grants read-data only) and ensures
/// claude's hardcoded scratch root exists (the cage can write beneath it
/// but cannot create it: /tmp itself stays metadata-only). Skips any
/// destination that already exists so user-owned agent state wins.
/// Best-effort: failures leave the agent to report its own missing
/// credentials.
///
/// Portable FileManager logic, so it lives in this unguarded file next to
/// `AgentHomeStaging` rather than in the macOS-only supervisor.
func stageAgentHomes(cageHome: String, hostHome: String? = nil) {
    let manager = FileManager.default
    let hostHome = hostHome ?? ProcessInfo.processInfo.environment["HOME"] ?? ""
    for root in AgentHomeStaging.claudeScratchRoots() {
        try? manager.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    guard cageHome.hasPrefix("/"), cageHome.contains("\0") == false else { return }
    guard hostHome.hasPrefix("/"), hostHome.contains("\0") == false else { return }
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: cageHome, isDirectory: &isDirectory),
        isDirectory.boolValue
    else {
        return
    }
    for link in AgentHomeStaging.credentialLinks {
        let source = "\(hostHome)/\(link.source)"
        guard manager.isReadableFile(atPath: source) else { continue }
        let destination = "\(cageHome)/\(link.relative)"
        if manager.fileExists(atPath: destination) { continue }
        let parent = (destination as NSString).deletingLastPathComponent
        try? manager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try? manager.createSymbolicLink(atPath: destination, withDestinationPath: source)
    }
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
    // `realpath` additionally needs `file-read-metadata` on `/`: without it
    // every canonicalization fails with EPERM and toolchains that resolve
    // their own location (Python, xcrun) break. Metadata on the walk
    // prefixes lets tools resolve paths. Content outside the workspace and
    // the system prefixes below stays denied.
    // Mach/XPC policy comes from `SeatbeltMachPolicy` (denied by default,
    // narrowly allowed where proven necessary). It is not a grant of host
    // files, and host credential services stay unreachable.
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
    \(SeatbeltMachPolicy.sbplRules())
    (allow file-read-data (literal "/"))
    (allow file-read-metadata (literal "/"))
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
        (subpath "/sbin")
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
    ;; No Unix-domain rules by design. Seatbelt filters Unix sockets only
    ;; as bare `(local unix)` / `(remote unix)` with no path scope, and
    ;; connect bypasses the file rules entirely: allowing outbound Unix
    ;; would expose every host socket (SSH agent, Docker, daemons). Local
    ;; IPC uses TCP loopback instead, which is interface-scoped.
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
