import Foundation
import RVIsolation

/// Splits one input action across the host protocol's bounded frames while
/// preserving byte order. The caller sends all chunks on one ordered lease.
enum TerminalInputChunks {
    static let maximumTotalBytes = 1_048_576

    static func make(_ bytes: Data) -> [Data]? {
        guard bytes.isEmpty == false, bytes.count <= maximumTotalBytes else { return nil }
        let size = TerminalStreamLimits.maximumInputBytes
        return stride(from: 0, to: bytes.count, by: size).map { offset in
            bytes.subdata(in: offset..<min(offset + size, bytes.count))
        }
    }
}
