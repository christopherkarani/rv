import Foundation
import Synchronization
import Testing
@testable import RVMCP

/// A gate a test opens by hand: work that waits on it stands for a write
/// to a reader that is not reading.
private final class Gate: Sendable {
    private let opened = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)

    func pass() {
        entered.signal()
        opened.wait()
    }

    func open() { opened.signal() }
}

@Suite("MCPOutbox")
struct MCPOutboxTests {
    @Test func runsWorkInOrderOffTheCallersThread() {
        let outbox = MCPOutbox(limit: 100)
        let order = Mutex<[Int]>([])
        let caller = ObjectIdentifier(Thread.current)
        let elsewhere = Mutex(true)
        for index in 0..<50 {
            #expect(outbox.submit(cost: 1) {
                order.withLock { $0.append(index) }
                if ObjectIdentifier(Thread.current) == caller { elsewhere.withLock { $0 = false } }
            } == .queued)
        }
        outbox.close()
        #expect(outbox.waitUntilDone(until: Date().addingTimeInterval(60)))
        #expect(order.withLock { $0 } == Array(0..<50))
        #expect(elsewhere.withLock { $0 })
    }

    /// One item of any size goes when nothing waits; past that, what waits
    /// (the item being run included) is bounded.
    @Test func boundsWhatWaitsButAlwaysTakesOneItem() {
        let outbox = MCPOutbox(limit: 10)
        let gate = Gate()
        #expect(outbox.submit(cost: 25) { gate.pass() } == .queued)
        gate.entered.wait()
        #expect(outbox.submit(cost: 1) {} == .overflow)
        gate.open()
        outbox.close()
        #expect(outbox.waitUntilDone(until: Date().addingTimeInterval(60)))

        let small = MCPOutbox(limit: 10)
        let held = Gate()
        #expect(small.submit(cost: 4) { held.pass() } == .queued)
        held.entered.wait()
        #expect(small.submit(cost: 6) {} == .queued)
        #expect(small.submit(cost: 1) {} == .overflow)
        held.open()
        small.close()
        #expect(small.waitUntilDone(until: Date().addingTimeInterval(60)))
    }

    @Test func closeRunsItsLastItemAfterWhatIsQueuedThenRefuses() {
        let outbox = MCPOutbox(limit: 100)
        let order = Mutex<[String]>([])
        _ = outbox.submit(cost: 1) { order.withLock { $0.append("a") } }
        outbox.close { order.withLock { $0.append("last") } }
        #expect(outbox.submit(cost: 1) { order.withLock { $0.append("late") } } == .closed)
        #expect(outbox.waitUntilDone(until: Date().addingTimeInterval(60)))
        #expect(order.withLock { $0 } == ["a", "last"])
    }

    @Test func abandonDropsWhatHasNotStarted() {
        let outbox = MCPOutbox(limit: 100)
        let gate = Gate()
        let order = Mutex<[String]>([])
        _ = outbox.submit(cost: 1) {
            gate.pass()
            order.withLock { $0.append("running") }
        }
        gate.entered.wait()
        _ = outbox.submit(cost: 1) { order.withLock { $0.append("dropped") } }
        outbox.abandon { order.withLock { $0.append("last") } }
        // Still running: not done yet.
        #expect(outbox.waitUntilDone(until: Date()) == false)
        gate.open()
        #expect(outbox.waitUntilDone(until: Date().addingTimeInterval(60)))
        #expect(order.withLock { $0 } == ["running", "last"])
    }
}

@Suite("MCPLogRelay")
struct MCPLogRelayTests {
    /// A sink that does not return (stderr nobody reads) holds up neither
    /// the caller nor more than `limit` bytes; what is dropped is counted
    /// and said once the sink moves again.
    @Test func aStuckSinkNeitherBlocksNorGrowsAndDropsAreReported() {
        let gate = Gate()
        let lines = Mutex<[String]>([])
        let first = Mutex(true)
        let relay = MCPLogRelay(limit: 10) { line in
            if first.withLock({ value in defer { value = false }; return value }) { gate.pass() }
            lines.withLock { $0.append(line) }
        }
        relay.post("one")
        gate.entered.wait()
        relay.post("two")
        relay.post("three-is-long")
        relay.post("four")
        gate.open()
        #expect(relay.finish(until: Date().addingTimeInterval(60)))
        let seen = lines.withLock { $0 }
        #expect(seen.first == "one")
        #expect(seen.contains("two"))
        #expect(seen.contains("three-is-long") == false)
        relay.post("after")
        #expect(lines.withLock { $0 }.last == "after")
    }

    @Test func droppedLinesAreCountedInTheNextLine() {
        let gate = Gate()
        let lines = Mutex<[String]>([])
        let first = Mutex(true)
        let relay = MCPLogRelay(limit: 4) { line in
            if first.withLock({ value in defer { value = false }; return value }) { gate.pass() }
            lines.withLock { $0.append(line) }
        }
        relay.post("a")
        gate.entered.wait()
        relay.post("bbbbbbbb")
        relay.post("cccccccc")
        gate.open()
        // Let the first line through, then post again: the count goes first.
        #expect(relay.waitUntilIdle(until: Date().addingTimeInterval(60)))
        relay.post("d")
        #expect(relay.finish(until: Date().addingTimeInterval(60)))
        let seen = lines.withLock { $0 }
        #expect(seen.contains { $0.contains("2 log lines") && $0.contains("dropped") }, "\(seen)")
        #expect(seen.last == "d")
    }
}

@Suite("MCPBacklog")
struct MCPBacklogTests {
    @Test func aReaderWaitsWhileTheQueueIsBehindAndGoesOnOnceItCatchesUp() {
        let backlog = MCPBacklog(limit: 10)
        backlog.admit(8)
        let through = Mutex(false)
        let started = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            started.signal()
            backlog.admit(5)
            through.withLock { $0 = true }
            done.signal()
        }
        started.wait()
        // A correct backlog never lets it through here; a broken one may.
        #expect(through.withLock { $0 } == false)
        backlog.release(8)
        let finished = done.wait(timeout: .now() + 60) == .success
        #expect(finished)
        #expect(through.withLock { $0 })
        // One line of any size goes when nothing waits.
        backlog.release(5)
        backlog.admit(1_000)
        backlog.release(1_000)
    }
}
