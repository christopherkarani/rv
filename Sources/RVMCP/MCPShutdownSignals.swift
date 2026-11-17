#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import Synchronization

/// Makes SIGINT, SIGTERM and SIGHUP run serve's normal shutdown instead of
/// ending rv at once, which would leave every server's process group
/// running and unsupervised, and each call in flight without its record.
/// Every serve installs it, before it plans (the capability probe holds a
/// stopped child); one owner (serve's `run`) creates and cancels it.
package final class MCPShutdownSignals {
    package static let handled = [SIGINT, SIGTERM, SIGHUP]

    /// The signals heard, in order, and where each goes. The one part the
    /// signal deliveries share; it is behind its own lock.
    final class Heard: Sendable {
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
    private var previous: [(number: Int32, action: sigaction)] = []
    /// Whether signals are heard at all. False only on Linux when the relay
    /// pipe could not be made: then nothing was installed, and serve must
    /// not run (a signal would end rv with every server still running).
    package private(set) var installed = true
    #if canImport(Darwin)
    private var sources: [any DispatchSourceSignal] = []
    #endif

    /// `catching` installs a handler, so a signal's default action does not
    /// end rv while it is heard. A handler, unlike `SIG_IGN`, is reset to
    /// the default across `exec`, so a server spawned meanwhile starts with
    /// the defaults. A signal rv inherited ignored (`nohup`) stays ignored
    /// and is not heard. `cancel` puts back what was there. Tests pass
    /// false, with a signal discarded by default.
    ///
    /// macOS hears each signal through a dispatch source (kqueue), and the
    /// handler does nothing. Linux has no such source a multithreaded
    /// process can rely on (libdispatch's `signalfd` sees only a signal
    /// every thread blocks), so there the handler is how a signal is heard,
    /// whether or not `catching`: it writes the signal's number to a pipe
    /// that one thread reads (`MCPSignalRelay`).
    ///
    /// With `catching`, an inherited ignored SIGCHLD is also set back to
    /// the default, and left so by `cancel`: an ignored SIGCHLD reaps each
    /// child by itself, and a server's supervisor could then neither kill
    /// what is left of its group nor learn how it ended.
    package convenience init(_ numbers: [Int32], catching: Bool) {
        #if canImport(Darwin)
        self.init(numbers, catching: catching, relay: { _ in true })
        #else
        self.init(numbers, catching: catching, relay: MCPSignalRelay.listen)
        #endif
    }

    /// `relay`: what makes signals heard on Linux (`MCPSignalRelay`); a
    /// test passes one that fails.
    init(_ numbers: [Int32], catching: Bool, relay: (Heard) -> Bool) {
        if catching { Self.defaultChildSignal() }
        guard relay(heard) else {
            installed = false
            return
        }
        for number in numbers {
            var before = sigaction()
            guard sigaction(number, nil, &before) == 0 else { continue }
            if catching, Self.ignores(before) { continue }
            #if canImport(Darwin)
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
            #else
            var handler = sigaction()
            handler.__sigaction_handler.sa_handler = mcpShutdownSignalHandler
            #endif
            handler.sa_flags = SA_RESTART
            sigemptyset(&handler.sa_mask)
            if sigaction(number, &handler, nil) == 0 { previous.append((number, before)) }
        }
        Self.unblock(previous.map(\.number) + (catching ? [] : numbers))
    }

    /// A process started with these signals blocked (a parent's thread
    /// mask passes to its children) would never hear them: they are
    /// unblocked in this thread (and, on Linux, in the relay's thread, which
    /// lives as long as the process), and left so.
    static func unblock(_ numbers: [Int32]) {
        guard numbers.isEmpty == false else { return }
        var set = sigset_t()
        sigemptyset(&set)
        for number in numbers { sigaddset(&set, number) }
        _ = pthread_sigmask(SIG_UNBLOCK, &set, nil)
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
    /// still heard); the other order would leave the handler with nothing
    /// hearing it, and the signal would vanish.
    package func cancel() {
        for entry in previous.reversed() {
            var action = entry.action
            _ = sigaction(entry.number, &action, nil)
        }
        previous = []
        #if canImport(Darwin)
        for source in sources { source.cancel() }
        sources = []
        #else
        MCPSignalRelay.stopListening(heard)
        #endif
    }

    /// Runs `body` (planning) on a thread of its own and returns what it
    /// returned, or nil as soon as a signal is heard, before or while it
    /// runs: serve then ends at once, however long a secret provider or
    /// prompt holds the plan. A plan still running then is left to finish
    /// on its own, and nothing it returns is used.
    package func plan<T>(_ body: @escaping () -> T) -> T? {
        let planning = MCPPlanning(body)
        forward { planning.wake.signal() }
        Thread.detachNewThread { planning.run() }
        while true {
            planning.wake.wait()
            if first != nil { return nil }
            if let result = planning.result { return result }
        }
    }

    /// Serves `runtime` until it returns: each signal asks it to shut down
    /// (from the second on it hurries), then the signals are cancelled.
    /// Returns serve's exit status (`exitCode`).
    package func serve(_ runtime: MCPGatewayRuntime) -> Int32? {
        forward { runtime.requestShutdown() }
        let ending = runtime.run()
        cancel()
        return Self.exitCode(ending, signal: first)
    }

    /// How serve exits once the runtime returns: as killed by the first
    /// signal it heard, 1 when the client stopped reading (the runtime said
    /// why on stderr), otherwise successfully (nil).
    package static func exitCode(_ ending: MCPGatewayRuntime.Ending, signal: Int32?) -> Int32? {
        if let signal { return 128 + signal }
        return ending == .clientNotReading ? 1 : nil
    }

    private static func defaultChildSignal() {
        var current = sigaction()
        guard sigaction(SIGCHLD, nil, &current) == 0, ignores(current) else { return }
        var standard = sigaction()
        #if canImport(Darwin)
        standard.__sigaction_u.__sa_handler = SIG_DFL
        #else
        standard.__sigaction_handler.sa_handler = SIG_DFL
        #endif
        sigemptyset(&standard.sa_mask)
        _ = sigaction(SIGCHLD, &standard, nil)
    }

    private static func ignores(_ action: sigaction) -> Bool {
        #if canImport(Darwin)
        let handler = action.__sigaction_u.__sa_handler
        #else
        let handler = action.__sigaction_handler.sa_handler
        #endif
        return unsafeBitCast(handler, to: Int.self) == unsafeBitCast(SIG_IGN as sig_t?, to: Int.self)
    }
}

#if !canImport(Darwin)
/// How `MCPShutdownSignals` hears signals on Linux: the handler writes each
/// number to a pipe, and one thread hands what the pipe holds to whoever
/// listens now. The handler makes one `write`: it takes no lock and
/// allocates nothing. The pipe is made once and never closed: a handler
/// that has read the descriptor may still be about to write after a
/// `cancel`, and a closed descriptor's number could by then be another
/// file.
private enum MCPSignalRelay {
    /// The pipe's write end, or -1 before it exists. Read by the handler.
    fileprivate static let writeEnd = Atomic<Int32>(-1)
    private static let listener = Mutex<MCPShutdownSignals.Heard?>(nil)
    private static let started: Bool = start()

    /// Hands every signal from now on to `heard`; false if the pipe could
    /// not be made, and then nothing is installed.
    static func listen(_ heard: MCPShutdownSignals.Heard) -> Bool {
        guard started else { return false }
        listener.withLock { $0 = heard }
        return true
    }

    /// No new delivery to `heard` starts after this returns.
    static func stopListening(_ heard: MCPShutdownSignals.Heard) {
        listener.withLock { current in
            if current === heard { current = nil }
        }
    }

    private static func start() -> Bool {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return false }
        let (readEnd, writing) = (ends[0], ends[1])
        // Never inherited. A full pipe drops a signal instead of blocking its handler.
        guard fcntl(readEnd, F_SETFD, FD_CLOEXEC) == 0, fcntl(writing, F_SETFD, FD_CLOEXEC) == 0,
            fcntl(writing, F_SETFL, O_NONBLOCK) == 0
        else {
            _ = close(readEnd)
            _ = close(writing)
            return false
        }
        Thread.detachNewThread {
            // A thread that is sure to take serve's signals, whatever mask
            // the process started with.
            MCPShutdownSignals.unblock(MCPShutdownSignals.handled)
            var numbers = [UInt8](repeating: 0, count: 64)
            while true {
                let count = read(readEnd, &numbers, numbers.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                // Recorded outside the lock: `record` runs serve's action.
                guard let heard = listener.withLock({ $0 }) else { continue }
                for number in numbers.prefix(count) { heard.record(Int32(number)) }
            }
        }
        writeEnd.store(writing, ordering: .sequentiallyConsistent)
        return true
    }
}

/// The signal handler: async-signal-safe (`write`, an atomic load, `errno`).
private func mcpShutdownSignalHandler(_ number: Int32) {
    let saved = errno
    let descriptor = MCPSignalRelay.writeEnd.load(ordering: .sequentiallyConsistent)
    if descriptor >= 0 {
        var byte = UInt8(truncatingIfNeeded: number)
        _ = write(descriptor, &byte, 1)
    }
    errno = saved
}
#endif

/// One plan run off serve's thread for `MCPShutdownSignals.plan`: its
/// result once it returns, and the wake-up serve waits on (the plan ending,
/// or a signal). Unchecked: `body` runs only on the planning thread, and
/// `result` is behind its lock.
private final class MCPPlanning<T>: @unchecked Sendable {
    private let body: () -> T
    private let lock = NSLock()
    private var value: T?
    let wake = DispatchSemaphore(value: 0)

    init(_ body: @escaping () -> T) {
        self.body = body
    }

    func run() {
        let result = body()
        lock.lock()
        value = result
        lock.unlock()
        wake.signal()
    }

    var result: T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
