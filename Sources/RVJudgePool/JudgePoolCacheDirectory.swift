#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// The workers' compiled-model cache: a directory the supervisor creates
/// fresh at startup (owner-only, random name, in the per-user temporary
/// directory), passes to each worker as `--cache`, and removes when it
/// exits. Workers never read the shared `~/Library/Caches/rv-laya` cache, so
/// a compiled model planted there is not loaded when a worker (re)starts.
///
/// This is an interim measure, not a verified store: a process running as
/// the same user that can list the temporary directory can still find and
/// rewrite it while the supervisor runs. The verified, manifest-checked
/// store (PR #625) replaces it.
public enum JudgePoolCacheDirectory {
    static let prefix = "rv-judge-"
    private static let current = Mutex<String?>(nil)

    /// The per-user temporary directory (`confstr` on Darwin, which does not
    /// depend on the environment launchd gives the agent).
    public static func userTemporaryDirectory() -> String? {
        #if canImport(Darwin)
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
        #else
        return nil
        #endif
    }

    /// Creates `<parent>/rv-judge-<128 random bits>`, mode 0700, owned by
    /// this user, and not a symlink; nil otherwise.
    static func create(in parent: String) -> String? {
        var generator = SystemRandomNumberGenerator()
        let suffix = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
        let path = parent + "/" + prefix + suffix.joined()
        guard mkdir(path, 0o700) == 0, chmod(path, 0o700) == 0 else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o700 else { return nil }
        return path
    }

    /// Removes leftovers of earlier supervisors (killed before they could
    /// clean up): `rv-judge-*` directories this user owns, except `keeping`.
    /// A symlink of that name is removed as a link, never followed.
    static func sweep(in parent: String, keeping: String?) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return }
        for name in names where name.hasPrefix(prefix) {
            let path = parent + "/" + name
            guard path != keeping else { continue }
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == geteuid() else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Creates this supervisor's directory, sweeping older ones, and removes
    /// it again at exit.
    public static func prepare() -> String? {
        guard let parent = userTemporaryDirectory(), let path = create(in: parent) else { return nil }
        sweep(in: parent, keeping: path)
        current.withLock { $0 = path }
        atexit { JudgePoolCacheDirectory.removeCurrent() }
        return path
    }

    static func removeCurrent() {
        guard let path = current.withLock({ $0 }) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
