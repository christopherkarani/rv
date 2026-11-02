#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import RVIsolation

/// Counts closes of a worker-owned descriptor and records its number.
private final class DescriptorLedger: Sendable {
    private let state = Mutex((closes: 0, descriptor: Int32(-1)))

    func record(_ fd: Int32) {
        state.withLock { $0.descriptor = fd }
    }

    func noteClose() {
        state.withLock { $0.closes += 1 }
    }

    var closes: Int { state.withLock { $0.closes } }
    var descriptor: Int32 { state.withLock { $0.descriptor } }
}

private func descriptorIsOpen(_ fd: Int32) -> Bool {
    fd >= 0 && fcntl(fd, F_GETFD) != -1
}

/// Polls `condition` for up to `seconds`; used only to observe a worker
/// that the test itself released finishing its call.
private func eventually(_ seconds: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
    let stop = Date().addingTimeInterval(seconds)
    while Date() < stop {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return condition()
}

@Suite("DiskImageSyscallPool", .serialized)
struct DiskImageSyscallPoolTests {
    /// Sequential calls reuse the same worker instead of one thread per call.
    @Test func sequentialCallsReuseABoundedNumberOfThreads() {
        let pool = DiskImageSyscallPool(maxIdle: 2, maxWedged: 2)
        var finished = 0
        for _ in 0..<5_000 {
            if diskImageWaitForStat(allowance: nil, liveDeadline: { nil }, pool: pool, stat: { true }) == true {
                finished += 1
            }
        }
        #expect(finished == 5_000)
        #expect(pool.threadsStarted == 1)
    }

    /// A wedged call returns nil on schedule; the next call runs on a
    /// fresh worker, and the wedged one is reused only after it returns.
    @Test func wedgedCallTimesOutAndNextCallUsesAFreshWorker() {
        let pool = DiskImageSyscallPool(maxIdle: 2, maxWedged: 2)
        let gate = DispatchSemaphore(value: 0)
        let started = Date()
        let wedged = diskImageWaitForStat(allowance: 0.1, liveDeadline: { nil }, pool: pool) {
            gate.wait()
            return true
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(wedged == nil)
        #expect(elapsed >= 0.1)
        #expect(elapsed < 0.5)
        #expect(pool.wedgedCount == 1)

        #expect(diskImageWaitForStat(allowance: 1, liveDeadline: { nil }, pool: pool) { true } == true)
        #expect(pool.threadsStarted == 2)

        gate.signal()
        #expect(eventually { pool.wedgedCount == 0 })
        // Both workers are idle again; no third thread is needed.
        #expect(diskImageWaitForStat(allowance: 1, liveDeadline: { nil }, pool: pool) { true } == true)
        #expect(pool.threadsStarted == 2)
    }

    /// A live deadline that arms mid-call still stops the wait.
    @Test func liveDeadlineArmingDuringTheCallStopsTheWait() {
        let pool = DiskImageSyscallPool(maxIdle: 2, maxWedged: 2)
        let gate = DispatchSemaphore(value: 0)
        let armedAt = Date().addingTimeInterval(0.1)
        let started = Date()
        let result = diskImageWaitForStat(
            allowance: nil,
            liveDeadline: { Date() >= armedAt ? armedAt : nil },
            pool: pool
        ) {
            gate.wait()
            return true
        }
        #expect(result == nil)
        #expect(Date().timeIntervalSince(started) < 0.5)
        gate.signal()
        #expect(eventually { pool.wedgedCount == 0 })
    }

    /// Once `maxWedged` workers are stuck, a new call fails closed at once
    /// without running its body or starting a thread.
    @Test func wedgedCapFailsClosedWithoutStartingTheCall() {
        let pool = DiskImageSyscallPool(maxIdle: 2, maxWedged: 2)
        let gate = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            #expect(diskImageWaitForStat(allowance: 0.05, liveDeadline: { nil }, pool: pool) {
                gate.wait()
                return true
            } == nil)
        }
        #expect(pool.wedgedCount == 2)
        #expect(pool.threadsStarted == 2)

        let ran = Mutex(false)
        let started = Date()
        let refused = diskImageWaitForStat(allowance: 5, liveDeadline: { nil }, pool: pool) {
            ran.withLock { $0 = true }
            return true
        }
        #expect(refused == nil)
        #expect(Date().timeIntervalSince(started) < 0.1)
        #expect(ran.withLock { $0 } == false)
        #expect(pool.threadsStarted == 2)

        gate.signal()
        gate.signal()
        #expect(eventually { pool.wedgedCount == 0 })
        #expect(diskImageWaitForStat(allowance: 1, liveDeadline: { nil }, pool: pool) { true } == true)
        #expect(pool.threadsStarted == 2)
    }

    /// The worker owns the duplicate and closes it exactly once when the
    /// call completes before the stop.
    @Test func completedCallClosesTheDuplicateExactlyOnce() throws {
        let pool = DiskImageSyscallPool(maxIdle: 2, maxWedged: 2)
        let fd = open("/", O_RDONLY | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        let ledger = DescriptorLedger()
        let result = diskImageWaitForStat(duplicating: fd, allowance: 1, liveDeadline: { nil }, pool: pool) { copy in
            ledger.record(copy)
            var status = stat()
            let ok = fstat(copy, &status) == 0
            if close(copy) == 0 { ledger.noteClose() }
            return ok
        }
        #expect(result == true)
        #expect(ledger.descriptor != fd)
        #expect(ledger.closes == 1)
        #expect(descriptorIsOpen(fd))
    }

    /// An abandoned call leaves the duplicate open for the worker, which
    /// closes it exactly once when its call finally returns.
    @Test func abandonedCallLeavesTheDuplicateToTheWorker() throws {
        let pool = DiskImageSyscallPool(maxIdle: 2, maxWedged: 2)
        let fd = open("/", O_RDONLY | O_CLOEXEC)
        try #require(fd >= 0)
        let ledger = DescriptorLedger()
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let result = diskImageWaitForStat(duplicating: fd, allowance: 0.05, liveDeadline: { nil }, pool: pool) { copy in
            ledger.record(copy)
            entered.signal()
            gate.wait()
            if close(copy) == 0 { ledger.noteClose() }
            done.signal()
            return true
        }
        #expect(result == nil)
        entered.wait()
        close(fd)
        #expect(descriptorIsOpen(ledger.descriptor))
        #expect(ledger.closes == 0)
        gate.signal()
        done.wait()
        #expect(ledger.closes == 1)
        #expect(eventually { pool.wedgedCount == 0 })
    }

    /// A refused call never hands the duplicate to a body.
    @Test func refusedDuplicatingCallDoesNotRunTheBody() throws {
        let pool = DiskImageSyscallPool(maxIdle: 1, maxWedged: 1)
        let gate = DispatchSemaphore(value: 0)
        #expect(diskImageWaitForStat(allowance: 0.05, liveDeadline: { nil }, pool: pool) {
            gate.wait()
            return true
        } == nil)
        let fd = open("/", O_RDONLY | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        let ledger = DescriptorLedger()
        let result = diskImageWaitForStat(duplicating: fd, allowance: 1, liveDeadline: { nil }, pool: pool) { copy in
            ledger.record(copy)
            close(copy)
            return true
        }
        #expect(result == nil)
        #expect(ledger.descriptor == -1)
        gate.signal()
        #expect(eventually { pool.wedgedCount == 0 })
    }

    /// An idle worker beyond its idle timeout exits; the next call starts
    /// a replacement instead of finding a dead worker in the idle list.
    @Test func idleWorkerRetiresAndIsReplaced() {
        let pool = DiskImageSyscallPool(maxIdle: 1, maxWedged: 1, idleTimeout: 0.05)
        #expect(diskImageWaitForStat(allowance: 1, liveDeadline: { nil }, pool: pool) { true } == true)
        #expect(eventually { pool.idleCount == 0 })
        #expect(diskImageWaitForStat(allowance: 1, liveDeadline: { nil }, pool: pool) { true } == true)
        #expect(pool.threadsStarted == 2)
    }
}
