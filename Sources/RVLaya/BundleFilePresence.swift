#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Whether one judge-bundle file is there, by `lstat`: the last path
/// component is never followed (a symlink there counts as present, even to
/// nowhere); symlinks in the intermediate components are followed, as for
/// any path lookup. Only ENOENT is absence, the one answer that may lead to
/// the packs-only floor (which allows). Any other error (EACCES,
/// ENOTDIR, ELOOP, ENAMETOOLONG, ...) is `unknown`: an agent can provoke
/// those, so callers treat it as present-but-unusable and fail closed to
/// review. `FileManager.fileExists` reads every error as "absent" and must
/// not be used for bundle files.
public enum BundleFilePresence: Sendable, Equatable {
    case present
    case absent
    /// The check itself failed; the text is the `strerror` of its errno.
    case unknown(String)

    public static func of(_ url: URL) -> BundleFilePresence {
        var info = stat()
        if lstat(url.path, &info) == 0 { return .present }
        let code = errno
        if code == ENOENT { return .absent }
        return .unknown(String(cString: strerror(code)))
    }

    /// True when present, false when absent; an unknown answer throws
    /// `CoreMLLoadRefusal` (review), recorded on `coreML` so doctor shows it.
    public static func exists(_ url: URL, recordingOn coreML: CoreMLGuard? = nil) throws(CoreMLLoadRefusal) -> Bool {
        switch of(url) {
        case .present: return true
        case .absent: return false
        case .unknown(let why):
            let refusal = CoreMLLoadRefusal(detail: "cannot check \(url.lastPathComponent): \(why)")
            coreML?.noteRefusal(refusal.reason)
            throw refusal
        }
    }
}
