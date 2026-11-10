/// Guest mounts that keep rv's workspace control paths out of the guest's
/// reach, mirroring `workspaceControlDenies` and `WorkspaceRunLaterPaths`
/// in RVIsolation's Seatbelt profile. Host git, rv, agents and editors
/// later read these paths outside any cage: a planted `.git/hooks/*`,
/// `core.hooksPath`/`core.fsmonitor` in `.git/config`, rv config under
/// `.rv` / `.config/rv`, or a hook in `.claude/settings.json`, `.mcp.json`,
/// `.vscode/tasks.json` or `.envrc` would run or apply on the host after
/// publish.
///
/// - Control paths are bind-mounted read-only over themselves.
/// - Pinned directories (`.git`, `.config`, `.claude`, `.codex`, `.cursor`,
///   `.gemini`, `.vscode`, and `.gemini/config`) are bind-mounted
///   read-write over themselves so they become mount points: the guest
///   cannot rename them aside and plant a replacement (rename and unlink of
///   a mount point fail with EBUSY).
/// - Guest processes lack CAP_SYS_ADMIN, so they cannot unmount any of it.
///
/// An empty pinned directory is mounted read-only whole: RVIsolation
/// creates empty placeholders for missing control paths before a run
/// (`MicroVMControlPlaceholders`), because a path that does not exist
/// cannot be mounted over. A pinned directory that is not empty but lacks a
/// protected child is refused. Top-level control paths, when absent, get no
/// mount.
///
/// `WorkspaceControlLayout` is the list of paths. RVIsolation keeps the
/// same lists in `WorkspaceRunLaterPaths` and `MicroVMControlLayout`;
/// `WorkspaceControlParityTests` in the main package fails when they drift.
public enum WorkspaceControlLayout {
    /// rv and git control paths. Same set as `workspaceControlDenies`.
    public static let controlFiles = [".git/config"]
    public static let controlTrees = [".git/hooks", ".rv", ".config/rv"]
    public static let controlPinnedDirectories = [".git", ".config"]

    /// Agent and editor config a host tool executes or trusts on its own.
    /// Same lists as `WorkspaceRunLaterPaths` in RVIsolation.
    public static let runLaterFiles = [
        ".claude/settings.json",
        ".claude/settings.local.json",
        ".mcp.json",
        ".codex/config.toml",
        ".codex/hooks.json",
        ".cursor/hooks.json",
        ".cursor/mcp.json",
        ".gemini/settings.json",
        ".gemini/config/hooks.json",
        ".vscode/tasks.json",
        ".vscode/settings.json",
        "opencode.json",
        "opencode.jsonc",
        ".envrc",
    ]
    public static let runLaterTrees = [
        ".claude/hooks",
        ".cursor/hooks",
        ".codex/hooks",
    ]
    public static let runLaterPinnedDirectories = [".claude", ".codex", ".cursor", ".gemini", ".vscode"]

    /// One protected path in the tree the mounts follow.
    public indirect enum Node: Equatable, Sendable {
        /// Mounted read-only over itself.
        case protected(String)
        /// Mounted read-write over itself when non-empty, with its protected
        /// children (each required) inside; read-only whole when empty.
        case pinned(String, [Node])

        public var name: String {
            switch self {
            case .protected(let name), .pinned(let name, _): name
            }
        }
    }

    /// Workspace-root nodes in mount order: rv and git control paths
    /// first, then agent and editor config.
    public static let roots: [Node] = tree(
        protected: controlTrees + controlFiles + runLaterFiles + runLaterTrees,
        pinnedRoots: controlPinnedDirectories + runLaterPinnedDirectories,
        order: [".git", ".rv", ".config"] + runLaterPinnedDirectories
    )

    /// Builds the tree from flat workspace-relative paths. A path under a
    /// pinned root goes inside it; an intermediate directory on the way to
    /// a deeper path (`.gemini/config`) is pinned too, so it cannot be
    /// renamed aside either.
    static func tree(protected: [String], pinnedRoots: [String], order: [String]) -> [Node] {
        func children(of prefix: String) -> [Node] {
            var names: [String] = []
            var deeper: [String: Bool] = [:]
            for path in protected where path.hasPrefix(prefix + "/") {
                let rest = path.dropFirst(prefix.count + 1)
                let first = String(rest.split(separator: "/", maxSplits: 1)[0])
                if deeper[first] == nil { names.append(first) }
                deeper[first] = (deeper[first] ?? false) || rest.contains("/")
            }
            return names.map { name in
                deeper[name] == true
                    ? .pinned(name, children(of: "\(prefix)/\(name)"))
                    : .protected(name)
            }
        }
        var roots: [Node] = []
        var seen = Set<String>()
        func add(_ name: String) {
            guard seen.insert(name).inserted else { return }
            roots.append(pinnedRoots.contains(name) ? .pinned(name, children(of: name)) : .protected(name))
        }
        for name in order { add(name) }
        for path in protected where path.contains("/") == false { add(path) }
        return roots
    }
}

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
        func pinned(_ relative: String, children: [WorkspaceControlLayout.Node]) -> Refusal? {
            switch kind(relative) {
            case .absent: return nil
            case .file, .emptyDirectory: return readOnly(relative)
            case .directory:
                mounts.append(Mount(path: "\(workspace)/\(relative)", readOnly: false))
                for child in children {
                    let path = "\(relative)/\(child.name)"
                    if kind(path) == .absent {
                        return .missingChild("\(workspace)/\(path)")
                    }
                    if let refusal = node(child, at: path) { return refusal }
                }
                return nil
            case .symlink, .other: return .unsupported("\(workspace)/\(relative)")
            }
        }
        func node(_ node: WorkspaceControlLayout.Node, at relative: String) -> Refusal? {
            switch node {
            case .protected: readOnly(relative)
            case .pinned(_, let children): pinned(relative, children: children)
            }
        }
        for root in WorkspaceControlLayout.roots {
            if let refusal = node(root, at: root.name) { return .failure(refusal) }
        }
        return .success(mounts)
    }
}
