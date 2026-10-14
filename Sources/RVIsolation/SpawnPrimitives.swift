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
    let original = fd
    fd = moved
    closeRelocatedOriginal(original)
    return true
}

/// One `close` of a relocated descriptor. Stdio stays open: this helper is
/// also used for pipes and directories, and a number below 3 may be the
/// process stdin. `close` is not retried: on Linux the kernel releases the
/// number before `EINTR`, and a second `close` would drop whatever was
/// opened there next.
func closeRelocatedOriginal(_ fd: Int32) {
    if fd < 3 { return }
    _ = close(fd)
}

/// One `close` of a socket this process just created or accepted. `socket`
/// and `accept` return 0, 1, or 2 only when that slot is free, so the
/// number is this socket and not an unrelated stdio stream. `close` is not
/// retried.
func closeOwnedSocket(_ fd: Int32) {
    if fd < 0 { return }
    _ = close(fd)
}

/// Darwin has no `SOCK_CLOEXEC`. The descriptor that survives is the
/// `F_DUPFD_CLOEXEC` result. The original, even when it is 0, 1, or 2, is
/// closed once on success and on dup failure. A failed dup returns `-1`
/// and does not leave the original open.
func publishCloexecSocket(raw: Int32, above floor: Int32) -> Int32 {
    guard raw >= 0 else { return -1 }
    let moved = fcntl(raw, F_DUPFD_CLOEXEC, floor)
    let dupError = errno
    closeOwnedSocket(raw)
    if moved < 0 {
        errno = dupError
        return -1
    }
    return moved
}

/// Moves an accepted socket above `floor`. `relocateDescriptor` does not
/// close an original below 3. This does, once, because that original is
/// the socket `accept` just returned. A failed move closes it once too.
func relocateOwnedSocket(_ fd: inout Int32, above floor: Int32) -> Bool {
    let original = fd
    guard original >= 0 else { return false }
    guard relocateDescriptor(&fd, above: floor) else {
        let failure = errno
        closeOwnedSocket(original)
        errno = failure
        return false
    }
    if original < 3, original != fd {
        closeOwnedSocket(original)
    }
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
