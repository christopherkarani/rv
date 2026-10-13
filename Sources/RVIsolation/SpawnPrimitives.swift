#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Moves `fd` at or above `floor` and closes the original, so low
/// numbers stay free for the child's granted set. The moved copy carries
/// close-on-exec; an fd already at or above the floor is untouched.
/// Returns false for an invalid fd or an `fcntl` failure; the original
/// stays open on failure and the caller maps the outcome to its own error.
func relocateDescriptor(_ fd: inout Int32, above floor: Int32) -> Bool {
    guard fd >= 0 else { return false }
    if fd >= floor { return true }
    let moved = fcntl(fd, F_DUPFD_CLOEXEC, floor)
    guard moved >= 0 else { return false }
    close(fd)
    fd = moved
    return true
}

/// C string vectors that live until `release()`.
struct SpawnPointers {
    private var storage: [UnsafeMutablePointer<CChar>?]

    init(_ values: [String]) {
        storage = values.map { value in
            value.withCString { strdup($0) }
        }
        storage.append(nil)
    }

    /// Runs `body` with the vector base pointer. Nil only when the vector is
    /// empty, which construction forbids (init always appends the terminator).
    func withPointers<T>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T? {
        var values = storage
        return values.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                return nil
            }
            return body(base)
        }
    }

    func release() {
        for pointer in storage {
            free(pointer)
        }
    }
}

/// Handshake wrapper script shared by both spawn paths. The child writes
/// `$1` (the nonce) to fd 3, closes it, then execs the payload.
let spawnHandshakeScript =
    "printf %s \"$1\" >&3 || exit 127; exec 3>&- || exit 127; shift; exec \"$@\""

/// Expected-prefix accumulation shared by the spawn wait loops. Each loop
/// keeps its own supervision policy; only this gate is shared.
struct HandshakePrefixMatcher {
    private let expected: Data
    private var accumulated: Data

    init(expected: Data, preface: Data = Data()) {
        self.expected = expected
        accumulated = preface
    }

    /// Appends `bytes`. Returns true once accumulated bytes start with the
    /// expected prefix AND accumulated count reaches the expected count.
    mutating func append(_ bytes: Data) -> Bool {
        accumulated.append(bytes)
        return accumulated.starts(with: expected) && accumulated.count >= expected.count
    }
}
