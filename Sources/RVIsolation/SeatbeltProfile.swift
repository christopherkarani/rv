#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// SBPL text compiled from a contained `IsolationPlan`. Production construction
/// is `compileSeatbeltProfile` only.
public struct SeatbeltProfile: Sendable, Equatable {
    public let source: String
    public let workspacePath: String

    init(source: String, workspacePath: String) {
        self.source = source
        self.workspacePath = workspacePath
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
/// `(deny default)` plus the execution baseline. No network allow.
/// Observed / mediated plans are not applicable. A contained plan with any
/// broader filesystem, network, or process guarantee is rejected.
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
    let source = """
    (version 1)
    (deny default)
    (allow process-exec*)
    (allow process-fork)
    (allow signal (target self))
    (allow sysctl-read)
    (allow mach-lookup)
    (allow file-read-data (literal "/"))
    (allow file-read-metadata
        (subpath "/private")
        (subpath "/tmp")
        (subpath "/var")
        (subpath "/Users"))
    (allow file-map-executable file-read* file-ioctl
        (subpath "/usr")
        (subpath "/bin")
        (subpath "/System")
        (subpath "/Library")
        (subpath "/dev")
        (subpath "\(escaped)"))
    (allow file-write*
        (subpath "\(escaped)"))
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
