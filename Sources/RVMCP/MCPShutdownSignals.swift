#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Synchronization

/// Makes SIGINT, SIGTERM and SIGHUP run serve's normal shutdown instead of
/// ending rv at once, which would leave each placeholder server's process
/// group running and unreaped. Serve installs it only when it names a
/// placeholder server, before it plans (the capability probe holds a
/// stopped child); one owner (serve's `run`) creates and cancels it.
package final class MCPShutdownSignals {
    package static let handled = [SIGINT, SIGTERM, SIGHUP]

    /// Whether a serve of `servers` catches signals; any other keeps the defaults.
    package static func wanted(by servers: [MCPServerDefinition]) -> Bool {
        servers.contains { $0.placeholders.isEmpty == false }
    }

    /// The signals heard, in order, and where each goes. The one part the
    /// dispatch sources' handlers share; it is behind its own lock.
    private final class Heard: Sendable {
        struct State {
            var numbers: [Int32] = []
            var action: (@Sendable () -> Void)?
        }

        let state = Mutex(State())

        func record(_ number: Int32) {
            let action = state.withLock { state in
                state.numbers.append(number)
                return state.action
            }
            action?()
        }
    }

    private let heard = Heard()
    #if canImport(Darwin)
    private var sources: [any DispatchSourceSignal] = []
    private var previous: [(number: Int32, action: sigaction)] = []
    #endif

    /// `catching` installs a handler that does nothing, so a signal's
    /// default action does not end rv while its source sees it. A handler,
    /// unlike `SIG_IGN`, is reset to the default across `exec`, so a server
    /// spawned meanwhile starts with the defaults. A signal rv inherited
    /// ignored (`nohup`) stays ignored and is not heard. `cancel` puts back
    /// what was there. Tests pass false, with a signal discarded by default.
    package init(_ numbers: [Int32], catching: Bool) {
        #if canImport(Darwin)
        for number in numbers {
            var before = sigaction()
            if catching {
                guard sigaction(number, nil, &before) == 0, Self.ignores(before) == false else { continue }
            }
            // The source first: a signal before the handler is in place
            // still has its default action, rather than vanishing.
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            let heard = self.heard
            source.setEventHandler { heard.record(number) }
            source.resume()
            sources.append(source)
            guard catching else { continue }
            var handler = sigaction()
            handler.__sigaction_u.__sa_handler = { _ in }
            handler.sa_flags = SA_RESTART
            sigemptyset(&handler.sa_mask)
            if sigaction(number, &handler, nil) == 0 { previous.append((number, before)) }
        }
        #endif
    }

    /// The first signal heard, if any: serve exits 128 plus it.
    package var first: Int32? {
        heard.state.withLock { $0.numbers.first }
    }

    /// Calls `action` once for each signal heard so far, then once for each
    /// one after. Serve forwards to its runtime once it has one.
    package func forward(to action: @escaping @Sendable () -> Void) {
        let pending = heard.state.withLock { state in
            state.action = action
            return state.numbers.count
        }
        for _ in 0..<pending { action() }
    }

    /// Restores the dispositions, then stops hearing signals. Idempotent.
    /// In that order a signal in between has its restored action (or is
    /// still heard); the other order would leave the no-op handler with no
    /// source, and the signal would vanish.
    package func cancel() {
        #if canImport(Darwin)
        for entry in previous.reversed() {
            var action = entry.action
            _ = sigaction(entry.number, &action, nil)
        }
        previous = []
        for source in sources { source.cancel() }
        sources = []
        #endif
    }

    #if canImport(Darwin)
    private static func ignores(_ action: sigaction) -> Bool {
        unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN as sig_t?, to: Int.self)
    }
    #endif
}
