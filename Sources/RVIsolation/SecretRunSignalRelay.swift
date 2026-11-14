#if os(Linux)
import Foundation
import Glibc
import Synchronization

/// How `rv run` hears the signals it forwards on Linux.
///
/// macOS ignores them (`SIG_IGN`) and reads them from a dispatch signal
/// source, which kqueue feeds even for an ignored signal. Linux discards an
/// ignored signal when it is sent, before libdispatch's `signalfd` could
/// read it, and a `signalfd` only sees a signal every thread blocks. So
/// here each forwarded signal has a handler that writes its number to a
/// pipe, and one thread delivers what the pipe holds. The handler makes
/// one `write`: it takes no lock and allocates nothing.
///
/// The pipe is made once and never closed: a handler that has read the
/// descriptor may still be about to write when a guard is removed, and a
/// closed descriptor's number could by then be another file.
enum SecretRunSignalRelay {
    /// The pipe's write end, or -1 before it exists. Read by the handler.
    fileprivate static let writeEnd = Atomic<Int32>(-1)
    private static let sink = Mutex<(@Sendable (Int32) -> Void)?>(nil)
    private static let started: Bool = start()

    /// Routes `numbers` to `deliver` until `remove`. The caller has already
    /// recorded their previous dispositions and restores them itself. If
    /// the pipe cannot be made the signals stay as the caller left them
    /// (ignored): rv then forwards nothing, and still ends with the command.
    static func install(_ numbers: [Int32], deliver: @escaping @Sendable (Int32) -> Void) {
        guard started else { return }
        sink.withLock { $0 = deliver }
        for number in numbers { _ = signal(number, secretRunRelayHandler) }
    }

    /// Nothing is delivered after this returns.
    static func remove() {
        sink.withLock { $0 = nil }
    }

    private static func start() -> Bool {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return false }
        let (readEnd, writeEnd) = (ends[0], ends[1])
        // Never inherited. A full pipe drops a signal instead of blocking its handler.
        guard fcntl(readEnd, F_SETFD, FD_CLOEXEC) == 0, fcntl(writeEnd, F_SETFD, FD_CLOEXEC) == 0,
            fcntl(writeEnd, F_SETFL, O_NONBLOCK) == 0
        else {
            _ = close(readEnd)
            _ = close(writeEnd)
            return false
        }
        Thread.detachNewThread {
            var numbers = [UInt8](repeating: 0, count: 64)
            while true {
                let count = read(readEnd, &numbers, numbers.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                // Under the lock, so `remove` returns only after a delivery in flight.
                sink.withLock { deliver in
                    for number in numbers.prefix(count) { deliver?(Int32(number)) }
                }
            }
        }
        self.writeEnd.store(writeEnd, ordering: .sequentiallyConsistent)
        return true
    }
}

/// The signal handler: async-signal-safe (`write`, an atomic load, `errno`).
private func secretRunRelayHandler(_ number: Int32) {
    let saved = errno
    let descriptor = SecretRunSignalRelay.writeEnd.load(ordering: .sequentiallyConsistent)
    if descriptor >= 0 {
        var byte = UInt8(truncatingIfNeeded: number)
        _ = write(descriptor, &byte, 1)
    }
    errno = saved
}
#endif
