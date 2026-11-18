import Foundation
import Synchronization

/// Work for one destination (the client's output, one upstream's input, one
/// remote connection, stderr), run in order on a thread of its own so the
/// gateway queue never waits for a reader that is slow or gone. What waits
/// is bounded by cost (bytes): an item is refused once taking it would put
/// more than `limit` in waiting, the item being run included. One item of
/// any size is taken when nothing waits, so a single legitimate line, up to
/// `MCPGatewayRuntime.maximumLineBytes`, always goes.
///
/// A dedicated thread, not a dispatch queue: work here may block for as long
/// as its reader does, and must still run while GCD's shared pool is held.
final class MCPOutbox: @unchecked Sendable {
    enum Admission: Equatable {
        case queued
        /// Taking it would pass the limit: the destination is not keeping up.
        case overflow
        /// `close` or `abandon` was called.
        case closed
    }

    private struct Item {
        var cost: Int
        var work: @Sendable () -> Void
    }

    let limit: Int
    private let condition = NSCondition()
    private var items: [Item] = []
    private var waiting = 0
    private var running = false
    private var closed = false
    /// The thread starts with the first item, so an outbox never used holds none.
    private var started = false

    init(limit: Int) {
        self.limit = limit
    }

    func submit(cost: Int, _ work: @escaping @Sendable () -> Void) -> Admission {
        condition.lock()
        defer { condition.unlock() }
        if closed { return .closed }
        if waiting > 0, waiting + cost > limit { return .overflow }
        items.append(Item(cost: cost, work: work))
        waiting += cost
        startIfNeeded()
        condition.broadcast()
        return .queued
    }

    /// Under the lock.
    private func startIfNeeded() {
        guard started == false else { return }
        started = true
        Thread.detachNewThread { [self] in drain() }
    }

    /// Takes nothing more. What is queued runs, then `last`, then the thread
    /// ends.
    func close(_ last: (@Sendable () -> Void)? = nil) {
        end(discarding: false, last)
    }

    /// Takes nothing more and drops what has not started; `last` runs once
    /// the item being run (if any) returns.
    func abandon(_ last: (@Sendable () -> Void)? = nil) {
        end(discarding: true, last)
    }

    private func end(discarding: Bool, _ last: (@Sendable () -> Void)?) {
        condition.lock()
        defer { condition.unlock() }
        guard closed == false else { return }
        closed = true
        if discarding {
            waiting -= items.reduce(0) { $0 + $1.cost }
            items.removeAll()
        }
        if let last {
            items.append(Item(cost: 0, work: last))
            startIfNeeded()
        }
        condition.broadcast()
    }

    /// True once nothing is queued or running; false if `deadline` came first.
    func waitUntilDone(until deadline: Date) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while items.isEmpty == false || running {
            if condition.wait(until: deadline) == false { return items.isEmpty && running == false }
        }
        return true
    }

    private func drain() {
        while true {
            condition.lock()
            while items.isEmpty, closed == false { condition.wait() }
            if items.isEmpty {
                condition.unlock()
                return
            }
            let item = items.removeFirst()
            running = true
            condition.unlock()
            item.work()
            condition.lock()
            waiting -= item.cost
            running = false
            condition.broadcast()
            condition.unlock()
        }
    }
}

/// `log` lines, written by an `MCPOutbox` so a stderr nobody reads never
/// holds up the gateway queue. At most `limit` bytes wait; lines past that
/// are dropped and counted, and the count goes out with the next line that
/// fits. After `finish`, lines go to the sink directly, as before.
final class MCPLogRelay: Sendable {
    private let outbox: MCPOutbox
    private let sink: @Sendable (String) -> Void
    private let dropped = Mutex(0)

    init(limit: Int, sink: @escaping @Sendable (String) -> Void) {
        outbox = MCPOutbox(limit: limit)
        self.sink = sink
    }

    func post(_ line: String) {
        let sink = sink
        dropped.withLock { count in
            let note = count == 0 ? nil : "\(count) log line\(count == 1 ? " was" : "s were") dropped: stderr was not being read"
            switch outbox.submit(cost: line.utf8.count, {
                if let note { sink(note) }
                sink(line)
            }) {
            case .queued: count = 0
            case .overflow: count += 1
            case .closed:
                if let note { sink(note) }
                sink(line)
                count = 0
            }
        }
    }

    func waitUntilIdle(until deadline: Date) -> Bool {
        outbox.waitUntilDone(until: deadline)
    }

    /// Writes what waits, for at most until `deadline`; later lines are
    /// written by the caller.
    func finish(until deadline: Date) -> Bool {
        outbox.close()
        return outbox.waitUntilDone(until: deadline)
    }
}

/// How far a reader thread may run ahead of the gateway queue, in bytes of
/// lines read and not yet handled. A reader waits (and so stops reading its
/// pipe, which holds up its writer, not the gateway) while `limit` bytes are
/// behind; one line of any size goes when nothing is.
final class MCPBacklog: @unchecked Sendable {
    let limit: Int
    private let condition = NSCondition()
    private var behind = 0

    init(limit: Int) {
        self.limit = limit
    }

    func admit(_ bytes: Int) {
        condition.lock()
        defer { condition.unlock() }
        while behind > 0, behind + bytes > limit { condition.wait() }
        behind += bytes
    }

    func release(_ bytes: Int) {
        condition.lock()
        defer { condition.unlock() }
        behind -= bytes
        condition.broadcast()
    }

    /// Adds `bytes` without waiting: what the reader's lines produced for a
    /// destination it waits on, until `release`d once written.
    func charge(_ bytes: Int) {
        condition.lock()
        defer { condition.unlock() }
        behind += bytes
    }
}

/// Whether a writer is getting anywhere: it is stalled once something has
/// waited for it, with no byte written, for a while. Time is measured on a
/// clock that stops while the machine sleeps.
final class MCPWriteProgress: Sendable {
    private struct State {
        var pending = 0
        var last = SuspendingClock.now
    }

    private let state = Mutex(State())

    func queued() {
        state.withLock {
            if $0.pending == 0 { $0.last = .now }
            $0.pending += 1
        }
    }

    func wrote() {
        state.withLock { $0.last = .now }
    }

    func finished() {
        state.withLock {
            $0.pending -= 1
            $0.last = .now
        }
    }

    func stalled(after seconds: TimeInterval) -> Bool {
        state.withLock { $0.pending > 0 && SuspendingClock.now - $0.last >= .milliseconds(Int64(seconds * 1000)) }
    }
}
