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

    /// Explicit, project-scoped resources selected by profile ID. The
    /// credential originals are deliberately absent: only private copies in
    /// `privateHome` can be seen by the contained process.
    func allowingResources(_ resources: RuntimeResourceManifest) -> SeatbeltProfile {
        var additions = """

        (allow file-read* file-write*
            (subpath "\(escapeSeatbeltSubpath(resources.privateHome))"))
        """
        for link in resources.profile.executableLinks {
            let target = canonicalResourcePath(link.target)
            additions += """

            (allow file-read* file-map-executable
                (literal "\(escapeSeatbeltSubpath(target))"))
            """
        }
        for path in resources.profile.readFiles {
            additions += """

            (allow file-read* file-map-executable
                (literal "\(escapeSeatbeltSubpath(canonicalResourcePath(path)))"))
            """
        }
        for path in resources.profile.readTrees {
            additions += """

            (allow file-read* file-map-executable
                (subpath "\(escapeSeatbeltSubpath(canonicalResourcePath(path)))"))
            """
        }
        for path in resources.profile.writeTrees {
            additions += """

            (allow file-read* file-write*
                (subpath "\(escapeSeatbeltSubpath(canonicalResourcePath(path)))"))
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

private func canonicalResourcePath(_ path: String) -> String {
    if let resolved = posixRealpath(path) { return resolved }
    let parent = (path as NSString).deletingLastPathComponent
    let name = (path as NSString).lastPathComponent
    if let resolvedParent = posixRealpath(parent) {
        return "\(resolvedParent)/\(name)"
    }
    return path
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
