import Foundation
import Testing
@testable import RVIsolation

/// Cancelled diskimage teardown stays inside the existing 8-second return
/// bound, and a preempted helper does not drop the serialization lock
/// while it, or the attach/mount it published, is still live.
@Suite("DiskImageCancellation")
struct DiskImageCancellationTests {
    @Test func cancelledDetachBudgetStaysInsideEightSeconds() {
        let helpers = DiskImageCancelBudget.cancelledDetachHelpers()
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
        #expect(helpers.detach == 5)
        #expect(helpers.detach <= DiskImageCancelBudget.detachCap)
        #expect(helpers.plainUnmount > 0)
        #expect(helpers.forceUnmount > 0)
        #expect(DiskImageCancelBudget.withinReturnBound(helpers))
        let sum = helpers.plainUnmount
            + helpers.forceUnmount
            + helpers.detach
            + DiskImageCancelBudget.preemptReap
            + DiskImageCancelBudget.preemptCleanup
        #expect(sum < DiskImageCancelBudget.returnBound)
        #expect(sum < 8)
    }

    @Test func cancelledUnmountAndDetachUseTheShortCaps() {
        let helpers = DiskImageCancelBudget.cancelledDetachHelpers()
        let plain = DiskImageCancelBudget.urgentDeadline(
            arguments: ["/sbin/umount", "/tmp/rv-workspace"]
        )
        let force = DiskImageCancelBudget.urgentDeadline(
            arguments: ["/sbin/umount", "-f", "/tmp/rv-workspace"]
        )
        let detach = DiskImageCancelBudget.urgentDeadline(
            arguments: ["/usr/bin/hdiutil", "detach", "-force", "-quiet", "/dev/disk3"]
        )
        #expect(plain == helpers.plainUnmount)
        #expect(force == helpers.forceUnmount)
        #expect(detach == helpers.detach)
        #expect(detach == 5)
        #expect(DiskImageCancelBudget.urgentDeadline(
            arguments: ["/usr/bin/hdiutil", "create", "-quiet", "/tmp/rv-inode-t.sparseimage"]
        ) == nil)
        #expect(DiskImageCancelBudget.urgentDeadline(
            arguments: ["/bin/sleep", "30"]
        ) == nil)
        let oneTeardown = (plain ?? 0) + (force ?? 0) + (detach ?? 0) + DiskImageCancelBudget.preemptReap
        #expect(oneTeardown < 8)
    }

    @Test func preemptedCreateUnlinksOnlyItsSparseImage() {
        let image = "/tmp/rv-inode-token.sparseimage"
        let create = [
            "/usr/bin/hdiutil", "create", "-size", "32m",
            "-fs", "Case-sensitive HFS+",
            "-volname", "rvtoken", "-type", "SPARSE", "-quiet", image,
        ]
        let plan = PreemptedDiskHelperCleanup.plan(arguments: create)
        #expect(plan == .unlinkSparseImage(image))
        #expect(plan.followUpArguments == nil)
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: true, cleanup: plan, cleanupFinished: true
        ) == false)
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: false, cleanup: plan, cleanupFinished: false
        ) == false)
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: false, cleanup: plan, cleanupFinished: true
        ))
    }

    @Test func preemptedAttachDetachesBeforeTheLockDrops() {
        let image = "/tmp/rv-inode-token.sparseimage"
        let attach = ["/usr/bin/hdiutil", "attach", "-nomount", "-plist", image]
        let plan = PreemptedDiskHelperCleanup.plan(arguments: attach)
        #expect(plan == .detachImage(image))
        #expect(plan.followUpArguments == [
            "/usr/bin/hdiutil", "detach", "-force", "-quiet", image,
        ])
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: false, cleanup: plan, cleanupFinished: false
        ) == false)
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: false, cleanup: plan, cleanupFinished: true
        ))
        let foreign = ["/usr/bin/hdiutil", "attach", "-nomount", "-plist", "/tmp/other.sparseimage"]
        #expect(PreemptedDiskHelperCleanup.plan(arguments: foreign) == .none)
    }

    @Test func preemptedMountUnmountsBeforeTheNextHelper() {
        let mount = [
            "/sbin/mount_hfs", "-o", "nobrowse,nodev,nosuid",
            "/dev/disk3s1", "/tmp/rv-workspace",
        ]
        let plan = PreemptedDiskHelperCleanup.plan(arguments: mount)
        #expect(plan == .unmount("/tmp/rv-workspace"))
        #expect(plan.followUpArguments == ["/sbin/umount", "-f", "/tmp/rv-workspace"])
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: true, cleanup: plan, cleanupFinished: true
        ) == false)
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: false, cleanup: plan, cleanupFinished: true
        ))
    }

    @Test func preemptedUnmountAndDetachDoNotStartAnotherHelper() {
        #expect(PreemptedDiskHelperCleanup.plan(
            arguments: ["/sbin/umount", "/tmp/rv-workspace"]
        ) == .none)
        #expect(PreemptedDiskHelperCleanup.plan(
            arguments: ["/sbin/umount", "-f", "/tmp/rv-workspace"]
        ) == .none)
        #expect(PreemptedDiskHelperCleanup.plan(
            arguments: ["/usr/bin/hdiutil", "detach", "-force", "-quiet", "/dev/disk3"]
        ) == .none)
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: true, cleanup: .none, cleanupFinished: true
        ) == false)
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: false, cleanup: .none, cleanupFinished: true
        ))
    }

    @Test func cancelledLockWaitStaysInsideEightSecondsAndOutlastsThePeer() {
        let budget = DiskImageCancelBudget.cancelledSequenceBudget
        let peer = (DiskImageCancelBudget.unmountWindow / 2) + DiskImageCancelBudget.signalGrace
            + (DiskImageCancelBudget.unmountWindow / 2) + DiskImageCancelBudget.signalGrace
            + DiskImageCancelBudget.detachCap + DiskImageCancelBudget.signalGrace
        #expect(peer == 7.5)
        #expect(budget == peer + DiskImageCancelBudget.preemptReap)
        #expect(budget > peer)
        #expect(budget < 8)
        #expect(budget < DiskImageCancelBudget.returnBound)
        let unbounded = DiskImageCancelBudget.lockWait(elapsedSinceCancel: 0, callerDeadline: nil)
        let historicalDefault = DiskImageCancelBudget.lockWait(elapsedSinceCancel: 0, callerDeadline: 45)
        let shortSlice = DiskImageCancelBudget.lockWait(elapsedSinceCancel: 0, callerDeadline: 0.5)
        #expect(unbounded == budget)
        #expect(historicalDefault == budget)
        #expect(historicalDefault != 45)
        #expect(shortSlice == budget)
        let almostDone = DiskImageCancelBudget.lockWait(elapsedSinceCancel: 7.6, callerDeadline: 45)
        #expect(abs(almostDone - 0.15) < 0.000_001)
        #expect(7.6 + almostDone < 8)
        #expect(DiskImageCancelBudget.lockWait(elapsedSinceCancel: 9, callerDeadline: nil) == 0)
    }

    @Test func urgentHolderYieldsSoTheSecondTeardownCanRun() {
        #expect(DiskImageCancelBudget.yieldsToWaiter(otherWaiters: 1, protectThisAcquire: false))
        #expect(DiskImageCancelBudget.yieldsToWaiter(otherWaiters: 1, protectThisAcquire: true) == false)
        #expect(DiskImageCancelBudget.yieldsToWaiter(otherWaiters: 0, protectThisAcquire: false) == false)
    }

    @Test func reapAfterSigkillStopsAtTheReturnDeadline() {
        let now = Date(timeIntervalSince1970: 1_000)
        let short = DiskImageCancelBudget.reapSlice(until: now.addingTimeInterval(0.125), now: now)
        #expect(short == 0.125)
        #expect(short < DiskImageCancelBudget.preemptReap)
        #expect(
            DiskImageCancelBudget.reapSlice(until: now.addingTimeInterval(10), now: now)
                == DiskImageCancelBudget.preemptReap
        )
        #expect(DiskImageCancelBudget.reapSlice(until: now, now: now) == 0)
        let clock = DiskImageCancelClock()
        #expect(clock.deadline == nil)
        clock.arm(now: now)
        #expect(clock.deadline == now.addingTimeInterval(DiskImageCancelBudget.cancelledSequenceBudget))
        clock.arm(now: now.addingTimeInterval(5))
        #expect(clock.deadline == now.addingTimeInterval(DiskImageCancelBudget.cancelledSequenceBudget))
    }

    @Test func failedDetachDoesNotCountAsCleanupOrAllowRetry() {
        #expect(DiskImageCancelBudget.preemptCleanupSucceeded(status: 0, timedOut: false))
        #expect(DiskImageCancelBudget.preemptCleanupSucceeded(status: 1, timedOut: false) == false)
        #expect(DiskImageCancelBudget.preemptCleanupSucceeded(status: 0, timedOut: true) == false)
        let image = "/tmp/rv-inode-token.sparseimage"
        let plan = PreemptedDiskHelperCleanup.detachImage(image)
        #expect(diskImageMayRetryPreemptedHelper(cleanup: plan, cleanupSucceeded: false) == false)
        #expect(diskImageMayRetryPreemptedHelper(cleanup: plan, cleanupSucceeded: true))
        #expect(diskImageMayRetryPreemptedHelper(
            cleanup: .unlinkSparseImage(image),
            cleanupSucceeded: false
        ))
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: true,
            reapExpired: false,
            cleanup: plan,
            cleanupFinished: true
        ) == false)
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: true,
            reapExpired: true,
            cleanup: plan,
            cleanupFinished: false
        ) == false)
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: true,
            reapExpired: true,
            cleanup: plan,
            cleanupFinished: false,
            cleanupAttempted: true
        ) == false)
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: false,
            cleanup: plan,
            cleanupFinished: false,
            diskCanStillAppear: true
        ) == false)
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: false,
            cleanup: plan,
            cleanupFinished: false
        ) == false)
    }

    @Test func plistMissDetachesTheImageOrPublishedDiskNeverTheMountPoint() {
        let image = "/tmp/rv-inode-token.sparseimage"
        let mount = "/tmp/rv-workspace"
        #expect(DiskImageCancelBudget.detachTargetWhenPlistMissesDisk(
            image: image,
            plistStdout: "system-entities /dev/disk4 junk",
            mountPoint: mount
        ) == "/dev/disk4")
        #expect(DiskImageCancelBudget.detachTargetWhenPlistMissesDisk(
            image: image,
            plistStdout: "",
            mountPoint: mount
        ) == image)
        #expect(DiskImageCancelBudget.detachTargetWhenPlistMissesDisk(
            image: image,
            plistStdout: mount,
            mountPoint: mount
        ) != mount)
    }

    @Test func inFlightToolUsesTheCancelClockNotAFreshBudget() {
        let plain = ["/sbin/umount", "/tmp/rv-workspace"]
        let force = ["/sbin/umount", "-f", "/tmp/rv-workspace"]
        let detach = ["/usr/bin/hdiutil", "detach", "-force", "-quiet", "/dev/disk3"]
        let capped = DiskImageCancelBudget.inFlightLimit(
            callerDeadline: 45,
            spentSinceCancel: 0,
            arguments: plain
        )
        #expect(capped == DiskImageCancelBudget.cancelledDetachHelpers().plainUnmount)
        #expect(capped == 0.5)
        #expect(capped != 45)
        let spent: TimeInterval = 1
        let forceCap = DiskImageCancelBudget.inFlightLimit(
            callerDeadline: 45,
            spentSinceCancel: spent,
            arguments: force
        )
        #expect(forceCap == 0.5)
        let shared = spent + DiskImageCancelBudget.sequenceRemaining(spentSinceCancel: spent)
        #expect(shared < 8)
        #expect(shared < DiskImageCancelBudget.returnBound)
        let stacked = spent + DiskImageCancelBudget.cancelledSequenceBudget
        #expect(stacked >= 8)
        let detachCap = DiskImageCancelBudget.inFlightLimit(
            callerDeadline: 8,
            spentSinceCancel: 0,
            arguments: detach
        )
        #expect(detachCap == DiskImageCancelBudget.detachCap)
        #expect(detachCap == 5)
    }

    @Test func nonUrgentHolderYieldsToACancelledWaiter() {
        #expect(DiskImageCancelBudget.yieldsToWaiter(
            otherWaiters: 1,
            protectThisAcquire: true,
            holderIsUrgent: false
        ))
        #expect(DiskImageCancelBudget.yieldsToWaiter(
            otherWaiters: 1,
            protectThisAcquire: true,
            holderIsUrgent: true
        ) == false)
        #expect(DiskImageCancelBudget.yieldsToWaiter(
            otherWaiters: 0,
            protectThisAcquire: false,
            holderIsUrgent: false
        ) == false)
    }

    @Test func forceUnmountStaysHalfASecondSoTheSecondVolumeCanUnmount() {
        #expect(DiskImageCancelBudget.cancelledForceSlice(remaining: 7) == 0.5)
        #expect(DiskImageCancelBudget.cancelledForceSlice(remaining: 7) != 6)
        let helpers = DiskImageCancelBudget.cancelledDetachHelpers()
        let accounted = helpers.forceUnmount + DiskImageCancelBudget.signalGrace
        #expect(DiskImageCancelBudget.waiterCanUnmount(peerHold: accounted))
        let tooLong = (DiskImageCancelBudget.cancelledSequenceBudget - 1) + DiskImageCancelBudget.signalGrace
        #expect(DiskImageCancelBudget.waiterCanUnmount(peerHold: tooLong) == false)
        #expect(DiskImageCancelBudget.urgentDeadline(
            arguments: ["/sbin/umount", "-f", "/tmp/rv-workspace"]
        ) == 0.5)
    }

    @Test func failedDetachDoesNotUnlinkOrRetryAPublishedDisk() {
        #expect(diskImageMayRemoveImage(detachSucceeded: false) == false)
        #expect(diskImageMayRemoveImage(detachSucceeded: true))
        #expect(diskImageMayRetryCreate(
            publishedDisk: true,
            detachSucceeded: false,
            timedOut: false
        ) == false)
        #expect(diskImageMayRetryCreate(
            publishedDisk: true,
            detachSucceeded: true,
            timedOut: false
        ))
        #expect(diskImageMayRetryCreate(
            publishedDisk: false,
            detachSucceeded: false,
            timedOut: false
        ))
        #expect(diskImageMayRetryCreate(
            publishedDisk: false,
            detachSucceeded: true,
            timedOut: true
        ) == false)
        #expect(diskImageMayUnlinkPublishedImage(helperStillAlive: true, detachSucceeded: true) == false)
        #expect(diskImageMayUnlinkPublishedImage(
            helperStillAlive: false,
            detachSucceeded: true,
            diskCanStillAppear: false
        ))
        #expect(diskImageMayUnlinkPublishedImage(helperStillAlive: false, detachSucceeded: true) == false)
        #expect(diskImageMayUnlinkPublishedImage(helperStillAlive: false, detachSucceeded: false) == false)
    }

    @Test func preemptedCallerRetriesItsOwnImageAndDoesNotTouchAnotherDisk() {
        let image = "/tmp/rv-inode-token.sparseimage"
        let plan = PreemptedDiskHelperCleanup.detachImage(image)
        #expect(diskImageCleanupConfinedToCaller(plan))
        #expect(diskImageCleanupConfinedToCaller(.detachImage("/dev/disk3")) == false)
        #expect(diskImageCleanupConfinedToCaller(.unmount("/tmp/rv-workspace")))
        #expect(diskImageMayRetryPreemptedHelper(
            cleanup: plan,
            cleanupSucceeded: false,
            targetWasAbsent: true
        ))
        #expect(diskImageMayRetryPreemptedHelper(
            cleanup: plan,
            cleanupSucceeded: false,
            helperStillAlive: true,
            targetWasAbsent: true
        ) == false)
        #expect(diskImageMayRetryPreemptedHelper(
            cleanup: plan,
            cleanupSucceeded: false,
            targetWasAbsent: false
        ) == false)
        #expect(diskImageCleanupTargetWasAbsent(
            status: 1,
            timedOut: false,
            output: "hdiutil: detach failed - No such file or directory"
        ) == false)
        #expect(diskImageCleanupTargetWasAbsent(
            status: 1,
            timedOut: false,
            output: "hdiutil: detach failed - No such disk"
        ) == false)
        #expect(diskImageCleanupTargetWasAbsent(
            status: 1,
            timedOut: false,
            output: "hdiutil: detach failed - not currently attached"
        ))
        #expect(diskImageCleanupTargetWasAbsent(
            status: 1,
            timedOut: true,
            output: "No such file or directory"
        ) == false)
        #expect(diskImageCleanupTargetWasAbsent(
            status: 1,
            timedOut: false,
            output: "Resource busy"
        ) == false)
    }

    /// The 8-second return starts at cancel and includes the leader reap,
    /// the session-death poll, and the detach. A fresh 7.75s after those
    /// waits is the bug `cancellationTerminatesOwnedProcessesBeforeReturn`
    /// measures with `Date` interval < 8.
    @Test func wholeCancelSequenceStaysUnderEightSeconds() {
        let reap = DiskImageCancelBudget.leaderReap
        let session = DiskImageCancelBudget.sessionDeathWait
        #expect(reap == 0.25)
        #expect(session == 2)
        let reapThenFresh = reap + DiskImageCancelBudget.cancelledSequenceBudget
        #expect(reapThenFresh >= 8)
        #expect(reapThenFresh >= DiskImageCancelBudget.returnBound)
        let sessionThenFresh = reap + session + DiskImageCancelBudget.cancelledSequenceBudget
        #expect(sessionThenFresh >= 8)
        #expect(DiskImageCancelBudget.wholeSequenceStaysUnderReturnBound(reap: reap, sessionWait: 0))
        #expect(DiskImageCancelBudget.wholeSequenceStaysUnderReturnBound(reap: reap, sessionWait: session))
        let shared = DiskImageCancelBudget.wholeSequenceWallTime(reap: reap, sessionWait: session)
        #expect(shared < 8)
        #expect(shared < DiskImageCancelBudget.returnBound)
        let now = Date(timeIntervalSince1970: 5_000)
        let clock = DiskImageCancelClock()
        clock.arm(now: now, spentSinceCancel: reap + session)
        let end = clock.deadline
        #expect(end == now.addingTimeInterval(
            DiskImageCancelBudget.sequenceRemaining(spentSinceCancel: reap + session)
        ))
        #expect(seatbeltWatchDisposition(cancelled: true, leaderDead: false) == .leaderStillAlive)
        #expect(seatbeltWatchDisposition(cancelled: true, leaderDead: false) != .lifetimeBoundaryFailed)
        #expect(seatbeltWatchDisposition(cancelled: true, leaderDead: true) == .cancelled)
        #expect(seatbeltWatchDisposition(cancelled: false, leaderDead: false) == .lifetimeBoundaryFailed)
        #expect(seatbeltWatchDisposition(cancelled: false, leaderDead: true) == .proceed)
        #expect(DiskImageCancelBudget.boundedWait(spentSinceCancel: reap, cap: session) == session)
        #expect(DiskImageCancelBudget.boundedWait(spentSinceCancel: 7.6, cap: session) < 1)
    }

    /// A busy detach is not cleanup. The lock stays held and the attach is
    /// not retried while that disk is still published.
    @Test func busyDetachIsNotSuccessAndDoesNotDropTheLock() {
        let image = "/tmp/rv-inode-token.sparseimage"
        let plan = PreemptedDiskHelperCleanup.detachImage(image)
        let output = "hdiutil: detach failed - Resource busy"
        #expect(diskImageDetachIsBusy(status: 1, timedOut: false, output: output))
        #expect(DiskImageCancelBudget.preemptCleanupSucceeded(status: 1, timedOut: false) == false)
        #expect(diskImageCleanupTargetWasAbsent(status: 1, timedOut: false, output: output) == false)
        #expect(diskImageMayDropSerializationLock(
            helperStillAlive: false,
            cleanup: plan,
            cleanupFinished: false,
            cleanupAttempted: true,
            diskCanStillAppear: true
        ) == false)
        #expect(diskImageMayRetryPreemptedHelper(
            cleanup: plan,
            cleanupSucceeded: false,
            targetWasAbsent: false,
            diskCanStillAppear: true
        ) == false)
        #expect(diskImageMayUnlinkPublishedImage(
            helperStillAlive: false,
            detachSucceeded: false,
            diskCanStillAppear: true
        ) == false)
    }

    /// A timeout after the attach process was reaped still has to detach.
    /// A helper that is still alive is not detached: it can still publish.
    @Test func reapedAttachTimeoutStillDetaches() {
        let image = "/tmp/rv-inode-token.sparseimage"
        let plan = PreemptedDiskHelperCleanup.detachImage(image)
        #expect(diskImageMustDetachBeforeUnlock(
            cleanup: plan,
            helperStillAlive: false,
            preempted: false,
            timedOut: true,
            status: -1
        ))
        #expect(diskImageMustDetachBeforeUnlock(
            cleanup: plan,
            helperStillAlive: true,
            preempted: false,
            timedOut: true,
            status: -1
        ) == false)
        #expect(diskImageMustDetachBeforeUnlock(
            cleanup: .none,
            helperStillAlive: false,
            preempted: false,
            timedOut: true,
            status: -1
        ) == false)
    }

    /// Process exit plus detach 0 does not permit unlink or a second create
    /// while diskimagesd can still publish that image.
    @Test func processExitPlusDetachZeroDoesNotUnlinkOrRetry() {
        let image = "/tmp/rv-inode-token.sparseimage"
        let plan = PreemptedDiskHelperCleanup.detachImage(image)
        #expect(diskImageCanStillAppear(
            helperStillAlive: false,
            detachStatus: 0,
            detachTimedOut: false,
            detachOutput: "",
            imageListedAfterDetach: nil,
            waitedForPublication: false
        ))
        #expect(diskImageMayUnlinkPublishedImage(
            helperStillAlive: false,
            detachSucceeded: true,
            diskCanStillAppear: true
        ) == false)
        #expect(diskImageMayRetryCreate(
            publishedDisk: true,
            detachSucceeded: false,
            timedOut: false
        ) == false)
        #expect(diskImageMayRetryPreemptedHelper(
            cleanup: plan,
            cleanupSucceeded: true,
            helperStillAlive: false,
            diskCanStillAppear: true
        ) == false)
        #expect(diskImageMayRetryPreemptedHelper(
            cleanup: plan,
            cleanupSucceeded: false,
            targetWasAbsent: false,
            diskCanStillAppear: true
        ) == false)
        #expect(diskImageCanStillAppear(
            helperStillAlive: false,
            detachStatus: 0,
            detachTimedOut: false,
            detachOutput: "",
            imageListedAfterDetach: false,
            waitedForPublication: true
        ) == false)
        #expect(diskImageMayUnlinkPublishedImage(
            helperStillAlive: false,
            detachSucceeded: true,
            diskCanStillAppear: false
        ))
    }

    /// A tree copy longer than the time left on the one cancel clock stops
    /// before it consumes the detach slice. The return stays under 8 seconds.
    /// `returnBound` and `detachCap` are unchanged.
    @Test func largeCopyStopsBeforeDetachAndStaysUnderEightSeconds() throws {
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
        let timeLeft = DiskImageCancelBudget.cancelledSequenceBudget
        let budget = DiskImageCancelBudget.copyBudget(timeLeft: timeLeft)
        #expect(budget != nil)
        #expect((budget ?? 0) + DiskImageCancelBudget.detachCap <= timeLeft)
        #expect(DiskImageCancelBudget.detachStillFits(afterCopy: budget ?? 0, timeLeft: timeLeft))
        let tiny: TimeInterval = 0.01
        #expect(tiny < (budget ?? 0))
        let tinyWall = DiskImageCancelBudget.cancelReturnWithClippedCopy(
            copySeconds: tiny,
            timeLeft: timeLeft
        )
        #expect(tinyWall < 8)
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(DiskImageCancelBudget.copyMayContinue(
            deadline: now.addingTimeInterval(timeLeft),
            now: now
        ))
        #expect(DiskImageCancelBudget.copyMayContinue(
            deadline: now.addingTimeInterval(DiskImageCancelBudget.detachCap),
            now: now
        ) == false)
        #expect(DiskImageCancelBudget.copyMayContinue(deadline: nil, now: now))
        let shared = DiskImageCancelBudget.wholeSequenceWallTime(reap: 0.25, sessionWait: 2)
        #expect(shared < 8)
        #expect(shared == DiskImageCancelBudget.cancelledSequenceBudget)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source")
        let destURL = root.appendingPathComponent("dest")
        let payload = Data(repeating: 7, count: 256 * 1024)
        try payload.write(to: sourceURL)
        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        let source = try FileHandle(forReadingFrom: sourceURL)
        let destination = try FileHandle(forWritingTo: destURL)
        defer {
            try? source.close()
            try? destination.close()
        }
        let started = Date()
        let allowance: TimeInterval = 0.12
        let deadline = started.addingTimeInterval(DiskImageCancelBudget.detachCap + allowance)
        #expect(DiskImageCancelBudget.copyMayContinue(deadline: deadline, now: started))
        // The copy budget above the detach reserve is 0.12s. A slow runner's
        // sleep inside the first check used to expire that before any write.
        // Admit the read and the pre-write recheck on the original instant,
        // then sleep, so one slice lands and the rest of the fork does not.
        var byteChecks = 0
        let copied = copyFileLeavingDetachReserve(
            from: source.fileDescriptor,
            to: destination.fileDescriptor,
            mayContinue: { point in
                if point == .xattr { return false }
                byteChecks += 1
                if byteChecks <= 2 {
                    return DiskImageCancelBudget.copyMayContinue(deadline: deadline, now: started)
                }
                Thread.sleep(forTimeInterval: 0.05)
                return DiskImageCancelBudget.copyMayContinue(deadline: deadline, now: Date())
            },
            copyXattr: { _, _ in true }
        )
        #expect(copied == false)
        let written = try Data(contentsOf: destURL)
        #expect(written.isEmpty == false)
        #expect(written.count < payload.count)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < DiskImageCancelBudget.returnBound)
        let wall = DiskImageCancelBudget.cancelReturnWithClippedCopy(
            copySeconds: elapsed,
            timeLeft: timeLeft
        )
        #expect(wall < 8)
        #expect(wall < DiskImageCancelBudget.returnBound)
        #expect(diskImageLockWaitIsExpired(cancelled: false, cancelClockSpent: true) == false)
        #expect(diskImageLockWaitIsExpired(cancelled: true, cancelClockSpent: true))
        #expect(diskImageLockWaitIsExpired(cancelled: true, cancelClockSpent: false) == false)
        let sliceStart = Date(timeIntervalSince1970: 5_000)
        let sliceEnd = sliceStart.addingTimeInterval(45)
        #expect(diskImageNextWaitDeadline(
            current: sliceEnd,
            now: sliceStart.addingTimeInterval(30),
            cancelled: false,
            cancelDeadline: nil
        ) == sliceEnd)
        #expect(diskImageLockWaitIsExpired(
            cancelled: false,
            cancelClockSpent: false,
            acquireSliceSpent: true
        ))
        #expect(diskImageLockWaitIsExpired(
            cancelled: false,
            cancelClockSpent: true,
            acquireSliceSpent: false
        ) == false)
        #expect(diskImageLockWaitIsExpired(
            cancelled: true,
            cancelClockSpent: false,
            acquireSliceSpent: true
        ) == false)
    }

    /// The closure returns while the helper is alive. The publication hold
    /// blocks the next attach. Umount still proceeds, so a cancelled peer
    /// can unmount instead of spinning out the shard.
    @Test func closureReturnsWhileHelperAliveAndBusyDoesNotSpin() {
        let alive = diskImageSerializationExit(
            helperStillAlive: true,
            diskCanStillAppear: true,
            detachOutputContainsBusy: false
        )
        #expect(alive.closureReturned)
        #expect(alive.publicationHeld)
        #expect(alive.teardownMayProceed)
        #expect(alive.mayStartNextAttach == false)
        let image = "/tmp/rv-inode-token.sparseimage"
        #expect(diskImageMayStartHelper(
            publicationHeld: alive.publicationHeld,
            arguments: ["/usr/bin/hdiutil", "attach", "-nomount", "-plist", image]
        ) == false)
        #expect(diskImageMayStartHelper(
            publicationHeld: alive.publicationHeld,
            arguments: ["/usr/bin/hdiutil", "create", "-quiet", image]
        ) == false)
        #expect(diskImageMayStartHelper(
            publicationHeld: alive.publicationHeld,
            arguments: ["/sbin/mount_hfs", "-o", "nobrowse", "/dev/disk2s1", "/tmp/ws"]
        ) == false)
        #expect(diskImageMayStartHelper(
            publicationHeld: true,
            arguments: ["/sbin/umount", "/tmp/ws"]
        ))
        #expect(diskImageMayStartHelper(
            publicationHeld: true,
            arguments: ["/usr/bin/hdiutil", "detach", "-force", "-quiet", image]
        ))
        let busy = diskImageSerializationExit(
            helperStillAlive: false,
            diskCanStillAppear: true,
            detachOutputContainsBusy: true
        )
        #expect(busy.closureReturned)
        #expect(busy.publicationHeld)
        #expect(busy.teardownMayProceed)
        #expect(busy.mayStartNextAttach == false)
        #expect(diskImagePublicationGateUpdate(
            plan: .detachImage(image),
            helperStillAlive: true,
            diskCanStillAppear: true,
            busy: false
        ) == true)
        #expect(diskImagePublicationGateUpdate(
            plan: .detachImage(image),
            helperStillAlive: false,
            diskCanStillAppear: true,
            busy: true
        ) == true)
        #expect(diskImagePublicationGateUpdate(
            plan: .none,
            helperStillAlive: false,
            diskCanStillAppear: true,
            busy: false,
            parkedDiskCanStillAppear: true,
            publicationAlreadyHeld: true
        ))
        #expect(diskImagePublicationGateUpdate(
            plan: .none,
            helperStillAlive: false,
            diskCanStillAppear: false,
            busy: false,
            parkedHelperStillAlive: false,
            parkedDiskCanStillAppear: false,
            publicationAlreadyHeld: true
        ) == false)
        #expect(diskImageMayStartHelper(
            publicationHeld: false,
            arguments: ["/usr/bin/hdiutil", "attach", "-nomount", "-plist", image]
        ))
        #expect(diskImagePublicationGateUpdate(
            plan: .detachImage(image),
            helperStillAlive: false,
            diskCanStillAppear: false,
            busy: false
        ) == false)
        #expect(diskImagePublicationCanClear(
            helperStillAlive: true,
            diskCanStillAppear: false,
            imageKnown: true
        ) == false)
        let omittedWithoutWait = diskImageCanStillAppear(
            helperStillAlive: false,
            detachStatus: 0,
            detachTimedOut: false,
            detachOutput: "",
            imageListedAfterDetach: false,
            waitedForPublication: false
        )
        #expect(omittedWithoutWait)
        #expect(diskImagePublicationCanClear(
            helperStillAlive: false,
            diskCanStillAppear: omittedWithoutWait,
            imageKnown: true
        ) == false)
        let nilListingCanAppear = diskImageCanStillAppear(
            helperStillAlive: false,
            detachStatus: 0,
            detachTimedOut: false,
            detachOutput: "",
            imageListedAfterDetach: nil,
            waitedForPublication: true
        )
        #expect(nilListingCanAppear)
        #expect(diskImagePublicationCanClear(
            helperStillAlive: false,
            diskCanStillAppear: nilListingCanAppear,
            imageKnown: true
        ) == false)
        let goneAfterWait = diskImageCanStillAppear(
            helperStillAlive: false,
            detachStatus: 0,
            detachTimedOut: false,
            detachOutput: "",
            imageListedAfterDetach: false,
            waitedForPublication: true
        )
        #expect(goneAfterWait == false)
        #expect(diskImagePublicationCanClear(
            helperStillAlive: false,
            diskCanStillAppear: goneAfterWait,
            imageKnown: true
        ))
        #expect(diskImagePublicationCanClear(
            helperStillAlive: false,
            diskCanStillAppear: true,
            imageKnown: false
        ))
        #expect(diskImagePublicationHoldAfterUpdate(
            updateKeepsHold: false,
            planHasImage: false,
            parkedImageKnown: false,
            helperStillAlive: false,
            diskCanStillAppear: false
        ) == false)
        #expect(diskImagePublicationHoldAfterUpdate(
            updateKeepsHold: false,
            planHasImage: false,
            parkedImageKnown: true,
            helperStillAlive: false,
            diskCanStillAppear: false
        ))
        #expect(DiskImageCancelBudget.returnBound == 8)
    }

    /// An empty hdiutil listing, or a mount point it does not report, does
    /// not prove the disk is gone and does not authorize another attach.
    @Test func emptyListingDoesNotProveTheDiskIsGone() {
        let image = "/tmp/rv-inode-token.sparseimage"
        let empty = diskImageInfoListingShowsImage(
            parsedImageCount: 0,
            identity: image,
            imagePaths: []
        )
        #expect(empty == nil)
        let mount = diskImageInfoListingShowsImage(
            parsedImageCount: 2,
            identity: "/private/var/folders/ws",
            imagePaths: [image],
            mountPoints: []
        )
        #expect(mount == nil)
        #expect(diskImageCanStillAppear(
            helperStillAlive: false,
            detachStatus: 0,
            detachTimedOut: false,
            detachOutput: "",
            imageListedAfterDetach: empty,
            waitedForPublication: true
        ))
        #expect(diskImageCanStillAppear(
            helperStillAlive: false,
            detachStatus: 0,
            detachTimedOut: false,
            detachOutput: "",
            imageListedAfterDetach: mount,
            waitedForPublication: true
        ))
        #expect(diskImageInfoListingShowsImage(
            parsedImageCount: 1,
            identity: image,
            imagePaths: ["/tmp/rv-inode-other.sparseimage"]
        ) == false)
        let alias = "/private/var/folders/ab/rv-inode-token.sparseimage"
        let local = "/var/folders/ab/rv-inode-token.sparseimage"
        #expect(diskImageSamePath(local, alias))
        #expect(diskImageSamePath(
            "/tmp/rv-inode-token.sparseimage",
            "/private/tmp/rv-inode-token.sparseimage"
        ))
        #expect(diskImageSamePath(
            "/private/var/folders/ab/rv-inode-token.sparseimage",
            "/System/Volumes/Data/private/var/folders/ab/rv-inode-token.sparseimage"
        ))
        #expect(diskImageSamePath(
            "/tmp/link/rv-inode-token.sparseimage",
            "/private/var/folders/ab/rv-inode-token.sparseimage"
        ))
        #expect(diskImageInfoListingShowsImage(
            parsedImageCount: 1,
            identity: "/tmp/rv-inode-token.sparseimage",
            imagePaths: ["/private/tmp/rv-inode-token.sparseimage"]
        ) == true)
        #expect(diskImageInfoListingShowsImage(
            parsedImageCount: 1,
            identity: "/tmp/link/rv-inode-token.sparseimage",
            imagePaths: ["/private/var/folders/ab/rv-inode-token.sparseimage"]
        ) == true)
        #expect(diskImageInfoListingShowsImage(
            parsedImageCount: 1,
            identity: "/tmp/rv-inode-token.sparseimage",
            imagePaths: ["/private/tmp/rv-inode-other.sparseimage"]
        ) == false)
        let shown = diskImageInfoListingShowsImage(
            parsedImageCount: 1,
            identity: local,
            imagePaths: [alias]
        )
        #expect(shown == true)
        #expect(diskImageCanStillAppear(
            helperStillAlive: false,
            detachStatus: 0,
            detachTimedOut: false,
            detachOutput: "",
            imageListedAfterDetach: shown,
            waitedForPublication: true
        ))
        let stillHeld = diskImagePublicationGateUpdate(
            plan: .none,
            helperStillAlive: false,
            diskCanStillAppear: false,
            busy: false,
            parkedDiskCanStillAppear: true,
            publicationAlreadyHeld: true
        )
        #expect(stillHeld)
        #expect(diskImageMayStartHelper(
            publicationHeld: stillHeld,
            arguments: ["/usr/bin/hdiutil", "attach", "-nomount", "-plist", local]
        ) == false)
        #expect(diskImageMayRetryPreemptedHelper(
            cleanup: .detachImage(local),
            cleanupSucceeded: false,
            helperStillAlive: false,
            targetWasAbsent: false,
            diskCanStillAppear: true
        ) == false)
        #expect(establishCancelReportsCancelled(detachExitedZero: true) == false)
        #expect(establishCancelReportsCancelled(detachExitedZero: false) == false)
    }

    /// A directory walk stops while the detach reserve is still left.
    @Test func directoryListingStopsForTheDetachReserve() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<8 {
            FileManager.default.createFile(
                atPath: root.appendingPathComponent("file-\(index)").path,
                contents: Data("x".utf8)
            )
        }
        var checks = 0
        let stopped = readDirectoryNamesStoppingForDetachReserve(root.path) {
            checks += 1
            return checks <= 1
        }
        #expect(stopped == nil)
        #expect(checks >= 1)
        let now = Date(timeIntervalSince1970: 20_000)
        #expect(DiskImageCancelBudget.copyMayContinue(
            deadline: now.addingTimeInterval(DiskImageCancelBudget.detachCap),
            now: now
        ) == false)
        #expect(DiskImageCancelBudget.detachCap == 5)
        #expect(DiskImageCancelBudget.returnBound == 8)
        let listed = readDirectoryNamesStoppingForDetachReserve(root.path) { true }
        #expect(listed?.count == 8)
    }

    /// A cancelled publish does not ftruncate the saved file, and a clock
    /// stop is not success even when a row was already rejected.
    @Test func cancelledPublishDoesNotCommitATruncatedTree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("saved")
        let sourceURL = root.appendingPathComponent("volume")
        let originalBytes = Data(repeating: 0x41, count: 200_000)
        let sourceBytes = Data(repeating: 0x42, count: 200_000)
        try originalBytes.write(to: originalURL)
        try sourceBytes.write(to: sourceURL)
        let original = try FileHandle(forUpdating: originalURL)
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer {
            try? original.close()
            try? source.close()
        }
        var xattrCalled = false
        let published = replaceOriginalOnlyAfterStagedCopy(
            source: source.fileDescriptor,
            original: original.fileDescriptor,
            originalPath: originalURL.path,
            mayContinue: { _ in false },
            copyXattr: { _, _ in
                xattrCalled = true
                return true
            }
        )
        #expect(published.committed == false)
        #expect(published.reachedTruncate == false)
        #expect(published.mayRenameOntoWorkspace)
        #expect(xattrCalled == false)
        #expect(try Data(contentsOf: originalURL) == originalBytes)
        #expect(savedTreePublishOutcome(
            clockAllowsCopy: false,
            rejected: true,
            stagedCopyFinished: false
        ) == .failed)
        #expect(savedTreePublishOutcome(
            clockAllowsCopy: false,
            rejected: false,
            stagedCopyFinished: true
        ) == .failed)
        #expect(mayReplaceSavedFile(stagedCopyFinished: true, clockAllowsCopy: false) == false)
        #expect(mayReplaceSavedFile(stagedCopyFinished: false, clockAllowsCopy: true) == false)
        try source.seek(toOffset: 0)
        var chunks = 0
        let partial = replaceOriginalOnlyAfterStagedCopy(
            source: source.fileDescriptor,
            original: original.fileDescriptor,
            mayContinue: { point in
                if point == .xattr { return false }
                chunks += 1
                return chunks <= 1
            },
            copyXattr: { _, _ in
                xattrCalled = true
                return true
            }
        )
        #expect(partial.committed == false)
        #expect(partial.reachedTruncate == false)
        #expect(partial.originalIntact)
        #expect(xattrCalled == false)
        #expect(try Data(contentsOf: originalURL) == originalBytes)
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
    }

    /// The xattr copy uses the same clock as the 64KB byte copy and stops
    /// while the detach reserve is still left.
    @Test func xattrCopyStopsBeforeTheDetachReserveIsGone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-xattr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source")
        let destURL = root.appendingPathComponent("dest")
        let payload = Data(repeating: 9, count: 96 * 1024)
        try payload.write(to: sourceURL)
        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        let source = try FileHandle(forReadingFrom: sourceURL)
        let destination = try FileHandle(forWritingTo: destURL)
        defer {
            try? source.close()
            try? destination.close()
        }
        let now = Date(timeIntervalSince1970: 80_000)
        let reserve = now.addingTimeInterval(DiskImageCancelBudget.detachCap)
        var xattrCalled = false
        let copied = copyFileLeavingDetachReserve(
            from: source.fileDescriptor,
            to: destination.fileDescriptor,
            mayContinue: { point in
                if point == .xattr {
                    return DiskImageCancelBudget.copyMayContinue(deadline: reserve, now: now)
                }
                return true
            },
            copyXattr: { _, _ in
                xattrCalled = true
                return true
            }
        )
        #expect(copied == false)
        #expect(xattrCalled == false)
        #expect(DiskImageCancelBudget.copyMayContinue(deadline: reserve, now: now) == false)
        #expect(DiskImageCancelBudget.detachStillFits(
            afterCopy: 0,
            timeLeft: DiskImageCancelBudget.detachCap
        ))
        #expect(DiskImageCancelBudget.detachCap == 5)
        #expect(DiskImageCancelBudget.returnBound == 8)
        let written = try Data(contentsOf: destURL)
        #expect(written == payload)
        try assertXattrCopyStopsBeforeDetachReserve()
    }

    /// `ftruncate` has already run. The backup restore uses the clock. A
    /// short restore must not leave the truncated bytes, and it must not
    /// be renamed onto the workspace.
    @Test func shortRestoreAfterTruncateDoesNotReplaceTheWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("saved")
        let sourceURL = root.appendingPathComponent("volume")
        let originalBytes = Data(repeating: 0x41, count: 200_000)
        let sourceBytes = Data(repeating: 0x42, count: 64)
        try originalBytes.write(to: originalURL)
        try sourceBytes.write(to: sourceURL)
        let original = try FileHandle(forUpdating: originalURL)
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer {
            try? original.close()
            try? source.close()
        }
        let outcome = replaceOriginalOnlyAfterStagedCopy(
            source: source.fileDescriptor,
            original: original.fileDescriptor,
            originalPath: originalURL.path,
            mayContinue: { point in
                if point == .xattr { return true }
                let size = descriptorSize(original.fileDescriptor) ?? -1
                return size != 0
            },
            copyXattr: { _, _ in true }
        )
        #expect(outcome.reachedTruncate)
        #expect(outcome.committed == false)
        #expect(outcome.mayRenameOntoWorkspace == false)
        #expect(savedTreeMayRenameOntoWorkspace(originalIntact: true, restoreFinished: false) == false)
        #expect(try Data(contentsOf: originalURL) == originalBytes)
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
    }

    /// The backup lives on `temporaryDirectory`. The saved inode does not.
    /// `rename` across those volumes is `EXDEV`. A short restore must not
    /// leave the truncated file where the saved tree is.
    @Test func shortRestoreAcrossDevicesDoesNotLeaveTheTruncatedInode() throws {
        let temporary = FileManager.default.temporaryDirectory
        let other = URL(fileURLWithPath: "/dev/shm")
            .appendingPathComponent("rv-restore-exdev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(diskImageSameDevice(temporary.path, other.path) == false)
        let originalURL = other.appendingPathComponent(".rv-saved-token")
        let sourceURL = other.appendingPathComponent("volume")
        let originalBytes = Data(repeating: 0x41, count: 200_000)
        let sourceBytes = Data(repeating: 0x42, count: 64)
        try originalBytes.write(to: originalURL)
        try sourceBytes.write(to: sourceURL)
        let original = try FileHandle(forUpdating: originalURL)
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer {
            try? original.close()
            try? source.close()
        }
        let outcome = replaceOriginalOnlyAfterStagedCopy(
            source: source.fileDescriptor,
            original: original.fileDescriptor,
            originalPath: originalURL.path,
            mayContinue: { point in
                if point == .xattr { return true }
                let size = descriptorSize(original.fileDescriptor) ?? -1
                return size != 0
            },
            copyXattr: { _, _ in true }
        )
        #expect(outcome.reachedTruncate)
        #expect(outcome.committed == false)
        #expect(outcome.mayRenameOntoWorkspace == false)
        if FileManager.default.fileExists(atPath: originalURL.path) {
            #expect(try Data(contentsOf: originalURL) == originalBytes)
        } else {
            #expect(FileManager.default.fileExists(atPath: originalURL.path) == false)
        }
        let leftover = (try? Data(contentsOf: originalURL)) ?? Data([0])
        #expect(leftover.isEmpty == false)
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
    }
}

private func assertXattrCopyStopsBeforeDetachReserve() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-xattr-real-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("source")
    let destURL = root.appendingPathComponent("dest")
    FileManager.default.createFile(atPath: sourceURL.path, contents: Data("src".utf8))
    FileManager.default.createFile(atPath: destURL.path, contents: Data("dst".utf8))
    let source = try FileHandle(forUpdating: sourceURL)
    let destination = try FileHandle(forUpdating: destURL)
    defer {
        try? source.close()
        try? destination.close()
    }
    let name = "user.rv-fork"
    // Inline user attributes top out near 4KB here. Three chunks still
    // make one get and one set of the whole value fail this test.
    let value = [UInt8](repeating: 3, count: 3_000)
    let wrote = writeXattr(source.fileDescriptor, name, value)
    #expect(wrote)
    if wrote {
        let trace = XattrCopyTrace()
        let chunk = 1_000
        var checks = 0
        let started = Date()
        // Enough checks for the old integer walk to accept this value and
        // for one fsetxattr of all of it. A windowed copy stops first.
        let copied = copyXattrsObservingClock(
            from: source.fileDescriptor,
            to: destination.fileDescriptor,
            chunkBytes: chunk,
            trace: trace
        ) {
            checks += 1
            return checks <= 2 + (value.count / chunk)
        }
        #expect(copied == false)
        #expect(checks >= 1)
        #expect(trace.largestRead > 0)
        #expect(trace.largestRead <= chunk)
        #expect(trace.largestRead < value.count)
        #expect(trace.largestWrite < value.count)
        let landed = readXattr(destination.fileDescriptor, name)?.count ?? 0
        #expect(landed < value.count)
        #expect(Date().timeIntervalSince(started) < DiskImageCancelBudget.returnBound)
    }
    var walked = 0
    let stopped = copyXattrBytesObservingClock(byteCount: 192 * 1024, chunkBytes: 64 * 1024) {
        walked += 1
        return walked < 2
    }
    #expect(stopped == false)
    #expect(walked >= 1)
    #if canImport(Darwin)
    var fcopyChecks = 0
    let fcopy = copyXattrsWithFcopyfile(
        from: source.fileDescriptor,
        to: destination.fileDescriptor
    ) {
        fcopyChecks += 1
        return fcopyChecks < 2
    }
    #expect(fcopy == false)
    #expect(fcopyChecks >= 1)
    let fcopyLanded = readXattr(destination.fileDescriptor, name)?.count ?? 0
    #expect(fcopyLanded < value.count)
    #endif
}
