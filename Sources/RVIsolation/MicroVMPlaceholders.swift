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
/// `.rv` and `.config/rv` (see `workspaceControlDenies`). A VM can only
/// protect a path by mounting over it, and a missing path has nothing to
/// mount over. So before the first micro-VM run in a workspace, rv creates
/// each missing control path empty; `rv-microvm` then mounts it read-only
/// (an empty `.git` or `.config` is mounted read-only whole, so its children
/// are not needed). Placeholders are reference-counted across concurrent
/// micro-VM runs and removed after the last one ends, but only while still
/// empty: anything a host process put there stays.
///
/// If the host process dies mid-run, empty placeholders can be left in the
/// project. An empty `.rv`, `.config/rv` or `.git/hooks` changes nothing
/// for rv or git.
final class MicroVMControlPlaceholders: Sendable {
    static let shared = MicroVMControlPlaceholders()

    private struct Created: Sendable {
        let path: String
        let isDirectory: Bool
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
        func makeFile(_ path: String) -> Bool {
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return false }
            close(fd)
            created.append(Created(path: path, isDirectory: false))
            return true
        }
        /// `children` are ensured only inside a directory that already existed.
        func ensure(_ relative: String, children: [(String, Bool)]) -> String? {
            let path = "\(workspace)/\(relative)"
            switch kind(path) {
            case .absent:
                return makeDirectory(path) ? nil : path
            case .file:
                return nil
            case .unsupported:
                return path
            case .directory:
                for (child, isDirectory) in children {
                    let childPath = "\(path)/\(child)"
                    switch kind(childPath) {
                    case .absent:
                        let made = isDirectory ? makeDirectory(childPath) : makeFile(childPath)
                        if made == false { return childPath }
                    case .directory, .file:
                        continue
                    case .unsupported:
                        return childPath
                    }
                }
                return nil
            }
        }
        for (relative, children) in [
            (".git", [("hooks", true), ("config", false)]),
            (".rv", []),
            (".config", [("rv", true)]),
        ] {
            if let failed = ensure(relative, children: children) { return refuse(failed) }
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
                if lstat(item.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == 0 {
                    _ = unlink(item.path)
                }
            }
        }
    }
}
