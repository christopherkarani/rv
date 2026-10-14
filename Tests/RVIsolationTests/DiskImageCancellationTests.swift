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
    @Test func largeCopyStopsBeforeDetachAndStaysUnderEightSeconds() {
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
        let timeLeft = DiskImageCancelBudget.cancelledSequenceBudget
        let huge: TimeInterval = 30
        let budget = DiskImageCancelBudget.copyBudget(timeLeft: timeLeft)
        #expect(budget != nil)
        #expect((budget ?? 0) < huge)
        #expect((budget ?? 0) + DiskImageCancelBudget.detachCap <= timeLeft)
        let wall = DiskImageCancelBudget.cancelReturnWithClippedCopy(
            copySeconds: huge,
            timeLeft: timeLeft
        )
        #expect(wall < 8)
        #expect(wall < DiskImageCancelBudget.returnBound)
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
    }
}
