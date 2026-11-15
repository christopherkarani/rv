#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// One locked `write(2)` loop for stderr lines from processes that must
/// outlive a closed stderr (`rv mcp serve`, its sandbox proxies). A short or
/// interrupted write is finished; a closed stderr fails the write, which
/// returns, whatever the process's SIGPIPE disposition and whenever it is
/// called. The process's disposition is never changed, so what children
/// start with is unchanged too.
///
/// Darwin sends a write's SIGPIPE to the process, not the writing thread
/// (measured: a thread that blocks it still ends the process), so only the
/// descriptor can stop it: `F_SETNOSIGPIPE` on stderr. That flag belongs to
/// the open file, so another process writing to the same stderr also gets
/// EPIPE instead of SIGPIPE once rv has written there. Linux sends it to the
/// writing thread, which blocks it around the write and takes back the one
/// the write raised.
package enum StderrWriter {
    private static let lock = NSLock()

    package static func write(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.isEmpty == false else { return }
        lock.lock()
        defer { lock.unlock() }
        #if canImport(Darwin)
        _ = fcntl(STDERR_FILENO, F_SETNOSIGPIPE, 1)
        _ = writeAll(bytes)
        #else
        var pipeSignal = sigset_t()
        sigemptyset(&pipeSignal)
        sigaddset(&pipeSignal, SIGPIPE)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &pipeSignal, &previous)
        if writeAll(bytes) == EPIPE {
            var now = timespec(tv_sec: 0, tv_nsec: 0)
            _ = sigtimedwait(&pipeSignal, nil, &now)
        }
        pthread_sigmask(SIG_SETMASK, &previous, nil)
        #endif
    }

    /// Writes until done or a failure other than EINTR; the failure's errno, or 0.
    private static func writeAll(_ bytes: [UInt8]) -> Int32 {
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                #if canImport(Darwin)
                return Darwin.write(STDERR_FILENO, base + written, raw.count - written)
                #else
                return Glibc.write(STDERR_FILENO, base + written, raw.count - written)
                #endif
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return n < 0 ? errno : 0 }
            written += n
        }
        return 0
    }
}
