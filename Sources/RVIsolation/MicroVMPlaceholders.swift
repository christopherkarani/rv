#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Synchronization

/// Empty placeholders for workspace control paths that do not exist when a
/// micro-VM run starts.
///
/// The Seatbelt cage denies creating `.git`, `.git/hooks/*`, `.git/config`,
/// `.rv`, `.config/rv` and the agent and editor config in
/// `WorkspaceRunLaterPaths` (see `workspaceControlDenies`). A VM can only
/// protect a path by mounting over it, and a missing path has nothing to
/// mount over. So before the first micro-VM run in a workspace, rv creates
/// each missing control path empty; `rv-microvm` then mounts it read-only
/// (an empty pinned directory such as `.git` or `.claude` is mounted
/// read-only whole, so its children are not needed). A JSON placeholder
/// holds `{}` so a tool in the guest reads it as empty config, not a parse
/// error. Placeholders are reference-counted across concurrent micro-VM
/// runs and removed after the last one ends, but only while unchanged:
/// anything a host process put there stays.
///
/// If the host process dies mid-run, placeholders can be left in the
/// project. An empty `.rv`, `.config/rv`, `.git/hooks` or `.vscode`, an
/// empty `.envrc`, or a `{}` `.mcp.json` changes nothing for the tools that
/// read them.
final class MicroVMControlPlaceholders: Sendable {
    static let shared = MicroVMControlPlaceholders()

    private struct Created: Sendable {
        let path: String
        let isDirectory: Bool
        /// What a file placeholder was created with; removal requires it unchanged.
        var contents: [UInt8] = []
    }

    private struct Entry: Sendable {
        var holders: Int
        var created: [Created]
    }

    private let entries = Mutex<[String: Entry]>([:])

    init() {}

    func acquire(workspace: String) -> Result<Void, IsolationApplyError> {
        entries.withLock { entries in
            // Every acquire re-ensures the control paths, not just the first:
            // another runtime may have filled a placeholder `.git` since, and
            // a non-empty `.git` without `hooks`/`config` children has nothing
            // to pin read-only.
            switch Self.create(workspace: workspace) {
            case .failure(let error):
                return .failure(error)
            case .success(let created):
                var entry = entries[workspace] ?? Entry(holders: 0, created: [])
                entry.holders += 1
                entry.created += created
                entries[workspace] = entry
                return .success(())
            }
        }
    }

    func release(workspace: String) {
        entries.withLock { entries in
            guard var entry = entries[workspace] else { return }
            entry.holders -= 1
            if entry.holders > 0 {
                entries[workspace] = entry
                return
            }
            entries[workspace] = nil
            Self.remove(entry.created)
        }
    }

    private enum Kind {
        case absent, directory, file, unsupported
    }

    private static func kind(_ path: String) -> Kind {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .absent : .unsupported }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        default: return .unsupported
        }
    }

    private static func create(workspace: String) -> Result<[Created], IsolationApplyError> {
        var created: [Created] = []
        func refuse(_ path: String) -> Result<[Created], IsolationApplyError> {
            remove(created)
            return .failure(.resourceStagingFailed(
                "workspace control path \(path) is not a plain file or directory; micro-VM launches refuse it"
            ))
        }
        func makeDirectory(_ path: String) -> Bool {
            guard mkdir(path, 0o755) == 0 else { return false }
            created.append(Created(path: path, isDirectory: true))
            return true
        }
        func makeFile(_ path: String, _ contents: [UInt8]) -> Bool {
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return false }
            // Recorded before the write: a short write still leaves a file rv made.
            created.append(Created(path: path, isDirectory: false, contents: contents))
            let written = contents.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            return written == contents.count
        }
        func make(_ node: MicroVMControlLayout.Node, at path: String) -> Bool {
            switch node {
            case .file(let name): makeFile(path, MicroVMControlLayout.placeholderContents(name))
            case .tree, .pinned: makeDirectory(path)
            }
        }
        /// Children are ensured only inside a pinned directory that already
        /// existed and is not empty: an empty one is mounted read-only whole,
        /// and adding children would make a later run mount it read-write.
        func ensure(_ node: MicroVMControlLayout.Node, at path: String) -> String? {
            switch kind(path) {
            case .absent:
                return make(node, at: path) ? nil : path
            case .file:
                return nil
            case .unsupported:
                return path
            case .directory:
                guard case .pinned(_, let children) = node else { return nil }
                if let entries = try? FileManager.default.contentsOfDirectory(atPath: path), entries.isEmpty { return nil }
                for child in children {
                    let childPath = "\(path)/\(child.name)"
                    switch kind(childPath) {
                    case .absent:
                        if make(child, at: childPath) == false { return childPath }
                    case .directory:
                        if let failed = ensure(child, at: childPath) { return failed }
                    case .file:
                        continue
                    case .unsupported:
                        return childPath
                    }
                }
                return nil
            }
        }
        for root in MicroVMControlLayout.roots {
            if let failed = ensure(root, at: "\(workspace)/\(root.name)") { return refuse(failed) }
        }
        return .success(created)
    }

    /// Newest first, so a child goes before its parent. `rmdir` refuses a
    /// directory that gained entries; a file goes only while still empty.
    private static func remove(_ created: [Created]) {
        for item in created.reversed() {
            if item.isDirectory {
                _ = rmdir(item.path)
            } else {
                var info = stat()
                guard lstat(item.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                    Int(info.st_size) == item.contents.count
                else { continue }
                let current = FileManager.default.contents(atPath: item.path).map { [UInt8]($0) }
                if current == item.contents {
                    _ = unlink(item.path)
                }
            }
        }
    }
}

/// The workspace control paths a micro-VM guest mounts over, as a tree.
///
/// Built from the same lists as the Seatbelt profile (`workspaceControlDenies`
/// and `WorkspaceRunLaterPaths`), so a path added there is protected in the
/// guest too. `WorkspaceControlLayout` in `Packages/rv-microvm` holds the
/// guest's copy; `WorkspaceControlParityTests` fails when the two drift.
enum MicroVMControlLayout {
    indirect enum Node: Equatable, Sendable {
        case file(String)
        case tree(String)
        case pinned(String, [Node])

        var name: String {
            switch self {
            case .file(let name), .tree(let name), .pinned(let name, _): name
            }
        }
    }

    /// rv and git control paths (same set as `workspaceControlDenies`).
    static let controlFiles = [".git/config"]
    static let controlTrees = [".git/hooks", ".rv", ".config/rv"]
    static let controlPinnedDirectories = [".git", ".config"]

    static let roots: [Node] = tree(
        protected: controlTrees + controlFiles + WorkspaceRunLaterPaths.files + WorkspaceRunLaterPaths.trees,
        trees: Set(controlTrees + WorkspaceRunLaterPaths.trees),
        pinnedRoots: controlPinnedDirectories + WorkspaceRunLaterPaths.pinnedDirectories,
        order: [".git", ".rv", ".config"] + WorkspaceRunLaterPaths.pinnedDirectories
    )

    /// `{}` for JSON config, so a guest tool reads an empty object; empty
    /// otherwise (`.git/config`, `config.toml` and `.envrc` accept that).
    static func placeholderContents(_ name: String) -> [UInt8] {
        name.hasSuffix(".json") || name.hasSuffix(".jsonc") ? Array("{}\n".utf8) : []
    }

    /// Same shape and order as `WorkspaceControlLayout.tree` in the guest
    /// package: a path under a pinned root goes inside it, and an
    /// intermediate directory on the way to a deeper path is pinned too.
    /// `trees` marks which leaves are directories.
    static func tree(protected: [String], trees: Set<String>, pinnedRoots: [String], order: [String]) -> [Node] {
        func leaf(_ path: String) -> Node {
            let name = String(path.split(separator: "/").last ?? Substring(path))
            return trees.contains(path) ? .tree(name) : .file(name)
        }
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
                deeper[name] == true ? .pinned(name, children(of: "\(prefix)/\(name)")) : leaf("\(prefix)/\(name)")
            }
        }
        var roots: [Node] = []
        var seen = Set<String>()
        func add(_ name: String) {
            guard seen.insert(name).inserted else { return }
            roots.append(pinnedRoots.contains(name) ? .pinned(name, children(of: name)) : leaf(name))
        }
        for name in order { add(name) }
        for path in protected where path.contains("/") == false { add(path) }
        return roots
    }
}
