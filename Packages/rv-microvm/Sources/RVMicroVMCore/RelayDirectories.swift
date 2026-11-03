import Foundation

/// Private host directories holding relay sockets. The owning pid is in the
/// name so a run that was SIGKILLed (supervisor cancel) can be swept later.
public enum RelayDirectories {
    public static let prefix = "rvmvm-"

    /// Owning pid from `rvmvm-<pid>.<suffix>`, nil for anything else.
    public static func owner(of name: String) -> pid_t? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let dot = rest.firstIndex(of: "."), rest.index(after: dot) < rest.endIndex else { return nil }
        return pid_t(rest[rest.startIndex..<dot])
    }

    /// Removes relay directories in `parent` whose owner is no longer alive.
    @discardableResult
    public static func sweep(in parent: String, isAlive: (pid_t) -> Bool) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return [] }
        var removed: [String] = []
        for name in names {
            guard let pid = owner(of: name), isAlive(pid) == false else { continue }
            let path = "\(parent)/\(name)"
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { continue }
            if (try? FileManager.default.removeItem(atPath: path)) != nil { removed.append(name) }
        }
        return removed
    }
}
