#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch

/// Makes SIGINT, SIGTERM and SIGHUP run serve's normal shutdown instead of
/// ending rv at once, which would leave each placeholder server's process
/// group running and unreaped. Serve installs it only when it bound a
/// placeholder server; one owner (serve's `run`) creates and cancels it.
package final class MCPShutdownSignals {
    package static let handled = [SIGINT, SIGTERM, SIGHUP]

    #if canImport(Darwin)
    private var sources: [any DispatchSourceSignal] = []
    private var previous: [(number: Int32, handler: sig_t?)] = []
    #endif

    /// `ignoring` first sets each signal to `SIG_IGN`, so its default action
    /// does not end rv before the source sees it; `cancel` puts back what was
    /// there. A signal rv inherited ignored (`nohup`) stays ignored and is
    /// not handled. Tests pass false, with a signal discarded by default.
    package init(_ numbers: [Int32], ignoring: Bool, handler: @escaping @Sendable (Int32) -> Void) {
        #if canImport(Darwin)
        for number in numbers {
            if ignoring {
                let before = signal(number, SIG_IGN)
                if Self.ignores(before) { continue }
                previous.append((number, before))
            }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { handler(number) }
            source.resume()
            sources.append(source)
        }
        #endif
    }

    /// Stops handling and restores the dispositions. Idempotent.
    package func cancel() {
        #if canImport(Darwin)
        for source in sources { source.cancel() }
        sources = []
        for entry in previous.reversed() { _ = signal(entry.number, entry.handler) }
        previous = []
        #endif
    }

    #if canImport(Darwin)
    private static func ignores(_ handler: sig_t?) -> Bool {
        unsafeBitCast(handler, to: Int.self) == unsafeBitCast(SIG_IGN as sig_t?, to: Int.self)
    }
    #endif
}
