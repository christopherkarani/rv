import Foundation
import RVDomain

/// Chunked SHA-256 over file bytes, as lowercase hex. Nil when the
/// file cannot be opened or read to end (missing, directory,
/// permission, mid-read IO failure). Follows symlinks exactly like
/// the exec path that consumes the measurement, so a swapped link
/// measures its new target. M4: custom-launch executable binding.
///
/// `maxBytes` caps the read: a file longer than the cap refuses
/// with nil instead of hashing to EOF. The spawn-commit caller
/// passes the dispatch-captured size, so a swapped-in huge file
/// refuses after one over-read chunk instead of stalling the
/// supervisor state lock. Nil (default) keeps unbounded hashing
/// for callers with no prior size.
enum RVFileDigest {
    static func sha256HexOfFile(atPath path: String, maxBytes: UInt64? = nil) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hash = RVSHA256Digest()
        var total: UInt64 = 0
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 64 * 1024)
            } catch {
                return nil
            }
            guard let chunk, chunk.isEmpty == false else { break }
            total += UInt64(chunk.count)
            guard maxBytes.map({ total <= $0 }) ?? true else { return nil }
            hash.update([UInt8](chunk))
        }
        return hash.digest().map { String(format: "%02x", $0) }.joined()
    }
}
