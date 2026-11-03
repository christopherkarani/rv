/// Guest mounts that keep rv's workspace control paths out of the guest's
/// reach, mirroring `workspaceControlDenies` in RVIsolation's Seatbelt
/// profile. Host git and rv later read these paths outside any cage: a
/// planted `.git/hooks/*`, `core.hooksPath`/`core.fsmonitor` in
/// `.git/config`, or rv config under `.rv` / `.config/rv` would run or
/// apply on the host after publish.
///
/// - Control paths are bind-mounted read-only over themselves.
/// - `.git` and `.config` directories are bind-mounted read-write over
///   themselves so they become mount points: the guest cannot rename them
///   aside and plant a replacement (rename and unlink of a mount point fail
///   with EBUSY).
/// - Guest processes lack CAP_SYS_ADMIN, so they cannot unmount any of it.
///
/// An empty `.git` or `.config` is mounted read-only whole: it is not a
/// repository, and RVIsolation creates such empty placeholders for missing
/// control paths before a run (`MicroVMControlPlaceholders`), because a
/// path that does not exist cannot be mounted over. A `.git` or `.config` directory that is
/// not empty but lacks a protected child is refused. `.git` / `.config` / `.rv`
/// themselves, when absent, get no mount.
public enum WorkspaceControlMounts {
    public enum Kind: Equatable, Sendable {
        case absent, directory, emptyDirectory, file, symlink, other
    }

    public struct Mount: Equatable, Sendable {
        public let path: String
        public let readOnly: Bool

        public init(path: String, readOnly: Bool) {
            self.path = path
            self.readOnly = readOnly
        }
    }

    public enum Refusal: Error, Equatable, CustomStringConvertible {
        /// A symlink would be followed out of the workspace when shared;
        /// any other type cannot be shared at all.
        case unsupported(String)
        /// A pinned control directory is writable, so a protected child that
        /// is absent could be planted by the guest and carried to the host.
        case missingChild(String)

        public var description: String {
            switch self {
            case .missingChild(let path):
                "workspace control path \(path) is missing; micro-VM launches refuse to leave it unprotected"
            case .unsupported(let path):
                "workspace control path \(path) is not a plain file or directory; micro-VM launches refuse it"
            }
        }
    }

    /// `kind` reports the type of a workspace-relative path without
    /// following symlinks (`lstat`). Mounts are ordered parents first.
    public static func plan(
        workspace: String,
        kind: (String) -> Kind
    ) -> Result<[Mount], Refusal> {
        var mounts: [Mount] = []
        func readOnly(_ relative: String) -> Refusal? {
            switch kind(relative) {
            case .absent: return nil
            case .directory, .emptyDirectory, .file:
                mounts.append(Mount(path: "\(workspace)/\(relative)", readOnly: true))
                return nil
            case .symlink, .other: return .unsupported("\(workspace)/\(relative)")
            }
        }
        func pinned(_ relative: String, children: [String]) -> Refusal? {
            switch kind(relative) {
            case .absent: return nil
            case .file, .emptyDirectory: return readOnly(relative)
            case .directory:
                mounts.append(Mount(path: "\(workspace)/\(relative)", readOnly: false))
                for child in children {
                    if kind("\(relative)/\(child)") == .absent {
                        return .missingChild("\(workspace)/\(relative)/\(child)")
                    }
                    if let refusal = readOnly("\(relative)/\(child)") { return refusal }
                }
                return nil
            case .symlink, .other: return .unsupported("\(workspace)/\(relative)")
            }
        }
        if let refusal = pinned(".git", children: ["hooks", "config"]) { return .failure(refusal) }
        if let refusal = readOnly(".rv") { return .failure(refusal) }
        if let refusal = pinned(".config", children: ["rv"]) { return .failure(refusal) }
        return .success(mounts)
    }
}
