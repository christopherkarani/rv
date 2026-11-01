#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization

/// Runs a short-lived helper.
///
/// The pipes are drained while the child runs. `waitUntilExit` before that
/// drain deadlocks once a child fills the pipe, and it also ignores task
/// cancellation. Under parallel launches DiskArbitration holds `hdiutil`
/// long enough that a cancelled test used to sit inside that wait until the
/// runner timed the test out. A helper with no deadline did the same thing:
/// a wedged `hdiutil` never returned, and the isolation job sat until GitHub
/// cancelled it. The default deadline kills that helper and returns.
/// Mount and unmount go through `mount_hfs`/`umount` directly instead of
/// arbitration-mediated `diskutil`, so they stay fast when the daemon is
/// unresponsive; only bare-disk attach/detach still use `hdiutil`.
/// Cancellation kills the helper and returns.
/// The executor runs this on `rv-executor-apply`; the poll sees that thread's
/// flag as well as `Task.isCancelled`. Cleanup calls pass
/// `honorCancellation: false` so a cancelled task can still detach the disk
/// it created. Diskimage helpers take `DiskImageToolSerialization.lock`
/// until the helper has exited or the reap deadline has passed. A preempted
/// attach or mount is detached or unmounted before a retry, and only when
/// that follow-up exits 0. Lock-wait time counts toward the cancelled
/// sequence clock, never the 45-second default. A cancel that arrives
/// during the wait notes a priority waiter on the next poll instead of
/// running the attempt as non-urgent. Urgent holders yield to that waiter
/// unless this acquire was granted a turn.
func runTool(
    _ arguments: [String],
    honorCancellation: Bool = false,
    deadline: TimeInterval? = 45,
    clock suppliedClock: DiskImageCancelClock = DiskImageCancelClock()
) -> ToolOutput {
    let clock = CooperativeLaunchStop.adoptCancelClock(suppliedClock)
    guard let executable = arguments.first else {
        return ToolOutput(status: 1, stdout: "", stderr: "missing executable")
    }
    guard DiskImageToolSerialization.contains(executable) else {
        return runToolBody(
            arguments,
            honorCancellation: honorCancellation,
            deadline: deadline,
            yieldToPriorityWaiter: false
        ).output
    }
    // A yield has no caller-visible failure. Before spawn, nothing ran.
    // Mid-flight, the helper was killed so this same teardown can take
    // the lock; retrying here keeps the caller's own retry for a real
    // diskimagesd failure. The preempted helper is reaped, and a partial
    // image, attach, or mount is cleaned, before the lock drops.
    let helperSlice = deadline
    let acquireSlice = deadline ?? 45
    // The 45-second slice starts when the lock is taken, not while a peer
    // holds it. A later poll does not move that end. The wait to take the
    // lock stops at 120 seconds, not at the 30-minute job cap and not at 45.
    let armedSlice = DiskImageArmedSlice()
    let peerWaitEnd = Date().addingTimeInterval(DiskImageCancelBudget.peerAcquireWait)
    var notedPriority = false
    var protectNext = false
    defer {
        if notedPriority {
            DiskImageToolSerialization.endPriorityWaiter()
        }
    }
    while true {
        if blockingWorkIsCancelled() {
            clock.arm(spentSinceCancel: CooperativeLaunchStop.spentSinceCancel())
        }
        if let end = clock.deadline {
            // The wait is the sequence clock. A 45-second default, or a
            // 0.5-second umount slice, must not expire it while a peer
            // still holds the lock.
            _ = diskImageNextWaitDeadline(
                current: end,
                now: Date(),
                cancelled: true,
                cancelDeadline: end
            )
            if diskImageLockWaitIsExpired(cancelled: true, cancelClockSpent: Date() >= end) {
                return ToolOutput(status: -1, stdout: "", stderr: "diskimage lock", timedOut: true)
            }
        } else if let armed = armedSlice.deadline {
            armedSlice.deadline = diskImageNextWaitDeadline(
                current: armed,
                now: Date(),
                cancelled: false,
                cancelDeadline: nil
            )
        }
        if blockingWorkIsCancelled(), notedPriority == false {
            DiskImageToolSerialization.notePriorityWaiter()
            notedPriority = true
        }
        let notedAtEntry = notedPriority
        let protectThis = protectNext
        protectNext = false
        let attempt = DiskImageToolSerialization.lock.withLockIfAvailable { _ -> DiskImageAttempt in
            if notedAtEntry {
                DiskImageToolSerialization.endPriorityWaiter()
            }
            let urgent = blockingWorkIsCancelled()
            DiskImageToolSerialization.beginHolding(urgent: urgent)
            let others = DiskImageToolSerialization.waiterCount()
            // A missed lock sets `protectThis` for this acquire. That turn
            // is only for an urgent holder. A non-urgent create or attach
            // still yields, so the cancelled waiter can unmount.
            if DiskImageCancelBudget.yieldsToWaiter(
                otherWaiters: others,
                protectThisAcquire: protectThis,
                holderIsUrgent: urgent
            ) {
                DiskImageToolSerialization.endHolding()
                return .yielded
            }
            let budgetEnd: Date
            if let cancelEnd = clock.deadline {
                budgetEnd = cancelEnd
            } else {
                armedSlice.deadline = diskImageAcquireSliceDeadline(
                    armed: armedSlice.deadline,
                    now: Date(),
                    slice: acquireSlice,
                    peerHoldsLock: false
                )
                budgetEnd = armedSlice.deadline ?? Date().addingTimeInterval(acquireSlice)
            }
            let remaining = budgetEnd.timeIntervalSinceNow
            if diskImagePeerWaitFailsBoundary(
                peerHoldsLock: false,
                acquireSliceSpent: remaining <= 0
            ) {
                DiskImageToolSerialization.endHolding()
                return .done(
                    ToolOutput(status: -1, stdout: "", stderr: "diskimage lock", timedOut: true)
                )
            }
            if DiskImageCancelBudget.mayRunPublicationRecheck(
                priorityWaiterQueued: DiskImageToolSerialization.hasPriorityWaiter(),
                cancelClockArmed: clock.deadline != nil
            ) {
                DiskImageToolSerialization.clearPublicationGateIfDiskIsGone(clock: clock)
            }
            if diskImageMayStartHelper(
                publicationHeld: DiskImageToolSerialization.publicationGateHeld(),
                arguments: arguments
            ) == false {
                DiskImageToolSerialization.endHolding()
                return .done(
                    ToolOutput(status: -1, stdout: "", stderr: "diskimage published", timedOut: true)
                )
            }
            var attemptSeconds = remaining
            if let helperSlice {
                attemptSeconds = min(attemptSeconds, helperSlice)
            }
            // Once the clock is armed, plain umount, force umount, and
            // detach all use `urgentDeadline`. Force is 0.5s, the slice
            // the sequence budget counts, not the time left minus 1s.
            if clock.deadline != nil,
                let urgentCap = DiskImageCancelBudget.urgentDeadline(arguments: arguments) {
                attemptSeconds = min(attemptSeconds, urgentCap)
            }
            let ran = runToolBody(
                arguments,
                honorCancellation: honorCancellation,
                deadline: attemptSeconds,
                yieldToPriorityWaiter: DiskImageCancelBudget.yieldsToWaiter(
                    otherWaiters: 1,
                    protectThisAcquire: protectThis,
                    holderIsUrgent: urgent
                ),
                parkIfStuck: false,
                returnDeadline: budgetEnd,
                clock: clock
            )
            let plan = PreemptedDiskHelperCleanup.plan(arguments: arguments)
            let returnDeadline = budgetEnd
            let mustDetach = diskImageMustDetachBeforeUnlock(
                cleanup: plan,
                helperStillAlive: ran.helperStillAlive,
                preempted: ran.preempted,
                timedOut: ran.output.timedOut,
                status: ran.output.status
            )
            if ran.helperStillAlive || ran.preempted || mustDetach {
                // One cleanup, then the closure returns. A live helper or a
                // busy detach keeps the publication hold so the next attach
                // does not start, and umount can take the mutex. "busy" is
                // not a reason to spin. An empty listing is not proof the
                // disk is gone, so it does not finish cleanup.
                var helperAlive = ran.helperStillAlive
                if helperAlive, clock.deadline != nil {
                    let slice = DiskImageCancelBudget.reapSlice(until: returnDeadline, now: Date())
                    let end = Date().addingTimeInterval(slice)
                    while helperAlive, Date() < end {
                        if parkedHelperIsAlive(ran.pid) == false {
                            helperAlive = false
                            break
                        }
                        usleep(10_000)
                    }
                }
                let cleanup: PreemptCleanupOutcome
                if helperAlive {
                    cleanup = PreemptCleanupOutcome(
                        succeeded: false,
                        targetWasAbsent: false,
                        busy: false,
                        diskCanStillAppear: true,
                        waitedForPublication: false
                    )
                } else {
                    // One publication wait, not a retry loop. An empty or
                    // unreported listing still does not prove the disk is gone.
                    let allowance = min(
                        DiskImageCancelBudget.preemptCleanup,
                        max(0, returnDeadline.timeIntervalSinceNow)
                    )
                    if allowance > 0 {
                        usleep(UInt32(allowance * 1_000_000))
                    }
                    cleanup = applyPreemptCleanup(
                        plan,
                        returnDeadline: returnDeadline,
                        clock: clock,
                        helperCanStillPublish: false,
                        waitedForPublication: allowance > 0
                    )
                }
                let exit = diskImageSerializationExit(
                    helperStillAlive: helperAlive,
                    diskCanStillAppear: helperAlive || cleanup.diskCanStillAppear,
                    detachOutputContainsBusy: cleanup.busy
                )
                DiskImageToolSerialization.notePublicationGate(
                    plan,
                    helperStillAlive: helperAlive,
                    diskCanStillAppear: helperAlive || cleanup.diskCanStillAppear,
                    busy: cleanup.busy,
                    pid: ran.pid
                )
                if helperAlive == false && cleanup.diskCanStillAppear == false && cleanup.busy == false {
                    if DiskImageCancelBudget.mayRunPublicationRecheck(
                        priorityWaiterQueued: DiskImageToolSerialization.hasPriorityWaiter(),
                        cancelClockArmed: clock.deadline != nil
                    ) {
                        DiskImageToolSerialization.clearPublicationGateIfDiskIsGone(clock: clock)
                    }
                }
                DiskImageToolSerialization.endHolding()
                let mayRetry = diskImageMayRetryPreemptedHelper(
                    cleanup: plan,
                    cleanupSucceeded: cleanup.succeeded,
                    helperStillAlive: helperAlive,
                    targetWasAbsent: cleanup.targetWasAbsent,
                    diskCanStillAppear: helperAlive || cleanup.diskCanStillAppear || cleanup.busy
                )
                if exit.mayStartNextAttach && mayRetry
                    && (ran.preempted || ran.output.status != 0) && ran.output.timedOut == false {
                    return .yielded
                }
                if exit.mayStartNextAttach == false || cleanup.busy || cleanup.diskCanStillAppear || helperAlive {
                    return .done(
                        ToolOutput(
                            status: -1,
                            stdout: "",
                            stderr: cleanup.busy ? "diskimage busy" : "preempt cleanup failed",
                            timedOut: true,
                            helperStillAlive: helperAlive
                        )
                    )
                }
                if ran.preempted || ran.output.timedOut {
                    var output = ran.output
                    output.helperStillAlive = helperAlive
                    return .done(output)
                }
            }
            if DiskImageCancelBudget.mayRunPublicationRecheck(
                priorityWaiterQueued: DiskImageToolSerialization.hasPriorityWaiter(),
                cancelClockArmed: clock.deadline != nil
            ) {
                DiskImageToolSerialization.clearPublicationGateIfDiskIsGone(clock: clock)
            }
            DiskImageToolSerialization.endHolding()
            var output = ran.output
            output.helperStillAlive = ran.helperStillAlive
            return .done(output)
        }
        if attempt != nil, notedAtEntry {
            notedPriority = false
        }
        switch attempt {
        case nil:
            protectNext = true
            if clock.deadline == nil,
                diskImagePeerWaitFailsBoundary(
                    peerHoldsLock: true,
                    acquireSliceSpent: false,
                    peerWaitSpent: Date() >= peerWaitEnd
                ) {
                return ToolOutput(status: -1, stdout: "", stderr: "diskimage lock", timedOut: true)
            }
            usleep(10_000)
        case .some(.done(let output)):
            return output
        case .some(.yielded):
            protectNext = true
            if let end = clock.deadline,
                diskImageLockWaitIsExpired(cancelled: true, cancelClockSpent: Date() >= end) {
                return ToolOutput(status: -1, stdout: "", stderr: "diskimage lock", timedOut: true)
            } else if diskImagePeerWaitFailsBoundary(
                peerHoldsLock: true,
                acquireSliceSpent: false,
                peerWaitSpent: Date() >= peerWaitEnd
            ) {
                return ToolOutput(status: -1, stdout: "", stderr: "diskimage lock", timedOut: true)
            }
            usleep(20_000)
        }
    }
}

struct HelperRun {
    var output: ToolOutput
    var preempted = false
    var helperStillAlive = false
    var pid: pid_t = 0
}

func runToolBody(
    _ arguments: [String],
    honorCancellation: Bool,
    deadline: TimeInterval?,
    yieldToPriorityWaiter: Bool,
    parkIfStuck: Bool = true,
    returnDeadline: Date? = nil,
    clock: DiskImageCancelClock? = nil
) -> HelperRun {
    guard let executable = arguments.first else {
        return HelperRun(output: ToolOutput(status: 1, stdout: "", stderr: "missing executable"))
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(arguments.dropFirst())
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    let outFD = output.fileHandleForReading.fileDescriptor
    let errFD = errors.fileHandleForReading.fileDescriptor
    guard setToolNonblocking(outFD), setToolNonblocking(errFD) else {
        return HelperRun(output: ToolOutput(status: 1, stdout: "", stderr: "pipe flags"))
    }
    do {
        try process.run()
    } catch {
        return HelperRun(output: ToolOutput(status: 1, stdout: "", stderr: String(describing: error)))
    }
    var stdout = Data()
    var stderr = Data()
    var limit = deadline.map { Date().addingTimeInterval($0) }
    if let returnDeadline, let existing = limit {
        limit = min(existing, returnDeadline)
    } else if let returnDeadline {
        limit = returnDeadline
    }
    var interrupted = false
    var timedOut = false
    var preempted = false
    var didArmCancel = false
    while process.isRunning {
        stdout.append(readToolPipe(outFD))
        stderr.append(readToolPipe(errFD))
        // `honorCancellation` stays false for umount and detach so a
        // cancelled task can still tear the disk down. Those helpers
        // used to keep the 45s snapshot they computed at spawn. Arm the
        // shared clock on the poll that first sees the flag, and cap
        // this process at the urgent slice. Time after that arm counts
        // against the same 7.75s; the next helper does not get another.
        if blockingWorkIsCancelled(),
            didArmCancel == false,
            DiskImageCancelBudget.urgentDeadline(arguments: arguments) != nil {
            didArmCancel = true
            let spent = CooperativeLaunchStop.spentSinceCancel()
            clock?.arm(spentSinceCancel: spent)
            let allowed = DiskImageCancelBudget.inFlightLimit(
                callerDeadline: deadline,
                spentSinceCancel: spent,
                arguments: arguments
            )
            var cap = Date().addingTimeInterval(allowed)
            if let end = clock?.deadline ?? CooperativeLaunchStop.cancelClock?.deadline {
                cap = min(cap, end)
            }
            limit = limit.map { min($0, cap) } ?? cap
        }
        let cancelled = honorCancellation && blockingWorkIsCancelled()
        let expired = limit.map { Date() >= $0 } ?? false
        // A cancelled teardown is waiting on the serialization lock.
        // Kill this helper immediately so that teardown can acquire the
        // lock inside its own deadline. `runTool` retries afterwards.
        // This is not a diskimagesd timeout.
        preempted = yieldToPriorityWaiter && DiskImageToolSerialization.hasPriorityWaiter()
        if preempted {
            interrupted = true
            kill(process.processIdentifier, SIGKILL)
            break
        }
        if cancelled || expired {
            interrupted = true
            timedOut = expired
            process.terminate()
            // Grace and the reap stop at the cancel clock. Adding them
            // after that deadline would put the return past 8 seconds.
            let stopAt = clock?.deadline ?? CooperativeLaunchStop.cancelClock?.deadline ?? returnDeadline
            let graceEnd = Date().addingTimeInterval(DiskImageCancelBudget.signalGrace)
            let graceStop = stopAt.map { min($0, graceEnd) } ?? graceEnd
            while process.isRunning, Date() < graceStop {
                stdout.append(readToolPipe(outFD))
                stderr.append(readToolPipe(errFD))
                usleep(10_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            break
        }
        usleep(10_000)
    }
    var helperStillAlive = false
    if interrupted {
        // Bounded reap, then park. `parkIfStuck: false` used to spin until
        // the process exited, so a D-state umount kept the cancelled caller
        // past 8 seconds. The return deadline cuts the reap short.
        let reapBound = clock?.deadline ?? CooperativeLaunchStop.cancelClock?.deadline ?? returnDeadline
        let reapDeadline = reapBound.map {
            Date().addingTimeInterval(DiskImageCancelBudget.reapSlice(until: $0, now: Date()))
        } ?? Date().addingTimeInterval(DiskImageCancelBudget.preemptReap)
        while process.isRunning, Date() < reapDeadline {
            stdout.append(readToolPipe(outFD))
            stderr.append(readToolPipe(errFD))
            usleep(10_000)
        }
        if process.isRunning {
            UnreapedToolProcesses.park(process)
            helperStillAlive = true
        } else {
            process.waitUntilExit()
        }
        _ = parkIfStuck
    } else {
        process.waitUntilExit()
    }
    stdout.append(readToolPipe(outFD))
    stderr.append(readToolPipe(errFD))
    try? output.fileHandleForReading.close()
    try? errors.fileHandleForReading.close()
    let status: Int32 = interrupted ? -1 : process.terminationStatus
    return HelperRun(
        output: ToolOutput(
            status: status,
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? "",
            timedOut: timedOut
        ),
        preempted: preempted,
        helperStillAlive: helperStillAlive,
        pid: helperStillAlive ? process.processIdentifier : 0
    )
}

/// Runs `/bin/sleep` until the current task is cancelled.
/// The status is `-1` when cancellation kills the helper.
func cancellableHelperProbe() -> Int32 {
    runTool(["/bin/sleep", "30"], honorCancellation: true, deadline: 30).status
}

private func setToolNonblocking(_ fd: Int32) -> Bool {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0 else { return false }
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0
}

private func readToolPipe(_ fd: Int32) -> Data {
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        // `O_NONBLOCK` does not stick on a Foundation pipe. A blocking
        // `read` here never returns to the deadline check, so a quiet
        // `hdiutil` holds the isolation job until the runner cancels it.
        var state = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&state, 1, 0)
        if ready < 0 {
            if errno == EINTR { continue }
            return bytes
        }
        if ready == 0 { return bytes }
        // `poll` also reports POLLHUP/POLLERR. `O_NONBLOCK` does not stick
        // on a Foundation pipe, so a `read` without POLLIN blocks and the
        // deadline above never runs. That is the isolation-job hang.
        if state.revents & Int16(POLLIN) == 0 { return bytes }
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return read(fd, base, raw.count)
        }
        if count > 0 {
            bytes.append(contentsOf: buffer.prefix(count))
            continue
        }
        if count < 0, errno == EINTR || errno == EAGAIN { return bytes }
        return bytes
    }
}

/// Foundation `Process.deinit` calls `waitUntilExit`. A helper stuck in
/// disk I/O after SIGKILL must stay referenced so that deinit cannot block
/// the caller. The array lives in a class: a mutable static is not
/// concurrency-safe, and `Process` is not `Sendable`, so a lock around a
/// `static var` does not satisfy Swift 6.
private final class ParkedToolProcesses: Sendable {
    private let box = Mutex<[Process]>([])

    func park(_ process: Process) {
        box.withLock { $0.append(process) }
    }

    /// `nil` when no parked helper has this pid. Answered from the
    /// retained process, then finished helpers are pruned: releasing
    /// an exited `Process` cannot block in `waitUntilExit`, and its
    /// pid must not be confused with a later unrelated process that
    /// reuses the number.
    func isRunning(pid: pid_t) -> Bool? {
        box.withLock { processes in
            // Answer from the retained process before pruning it: once
            // removed, a reused pid must not fall back to `kill`.
            let found = processes.first(where: { $0.processIdentifier == pid })?.isRunning
            processes.removeAll { $0.isRunning == false }
            return found
        }
    }
}

private enum UnreapedToolProcesses {
    private static let parked = ParkedToolProcesses()

    static func park(_ process: Process) {
        parked.park(process)
    }

    static func isRunning(pid: pid_t) -> Bool? {
        parked.isRunning(pid: pid)
    }
}

/// Liveness for a helper pid recorded by the publication gate. The
/// retained `Process` is the authority while it is parked: a bare pid
/// can be reused by an unrelated live process after the helper is
/// reaped, which would hold the gate forever. Only a pid that was
/// never parked here falls back to `kill(pid, 0)`.
func parkedHelperIsAlive(_ pid: pid_t) -> Bool {
    guard pid > 1 else { return false }
    if let running = UnreapedToolProcesses.isRunning(pid: pid) {
        return running
    }
    return kill(pid, 0) == 0
}
#endif
