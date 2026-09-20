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

    init(source: String) {
        self.source = source
    }
}

/// First-slice Seatbelt profile: allow-default + deny writes outside the
/// resolved workspace. Not a jail. Network stays unrestricted (no network rule).
/// Observed / mediated plans are not applicable.
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
        case .writesLimited(let limitedTo):
            guard limitedTo == workspace else {
                return .failure(.containedGuaranteesUnsupported)
            }
        case .unrestricted:
            return .failure(.containedGuaranteesUnsupported)
        }
        switch guarantees.descent {
        case .inherited:
            break
        case .notInherited:
            return .failure(.containedGuaranteesUnsupported)
        }
        switch guarantees.network {
        case .unrestricted:
            break
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
        if resolved.contains("\n") || resolved.contains("\0") {
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
    if resolved.contains("\n") || resolved.contains("\0") {
        return .failure(.workspacePathUnsafe)
    }
    let escaped = escapeSeatbeltSubpath(resolved)
    let source = """
    (version 1)
    (allow default)
    (deny file-write*
        (require-not (subpath "\(escaped)")))
    """
    return .success(SeatbeltProfile(source: source))
}

func escapeSeatbeltSubpath(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}
