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
        ))
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
}
