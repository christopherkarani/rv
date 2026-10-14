#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

private final class StatCallCount: @unchecked Sendable {
    var value = 0
}

private final class DeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date?
    var date: Date? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// Cancelled diskimage teardown stays inside the existing 8-second return
/// bound, and a preempted helper does not drop the serialization lock
/// while it, or the attach/mount it published, is still live.
// Serialized: several tests assert wall-clock bounds against shared
// clocks and thread state, which parallel suites on one runner skew.
@Suite("DiskImageCancellation", .serialized)
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
        // No static argv: detach takes the published devname, resolved
        // at the execution site, never the image path.
        #expect(plan.followUpArguments == nil)
        #expect(DiskImageCancelBudget.detachArguments(device: "/dev/disk4") == [
            "/usr/bin/hdiutil", "detach", "-force", "-quiet", "/dev/disk4",
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

    @Test func plistMissDetachesOnlyAPublishedDiskNeverTheImageOrMountPoint() {
        let image = "/tmp/rv-inode-token.sparseimage"
        let mount = "/tmp/rv-workspace"
        #expect(DiskImageCancelBudget.detachTargetWhenPlistMissesDisk(
            image: image,
            plistStdout: "system-entities /dev/disk4 junk",
            mountPoint: mount
        ) == "/dev/disk4")
        // Real plist XML wraps the device in a string element.
        #expect(DiskImageCancelBudget.detachTargetWhenPlistMissesDisk(
            image: image,
            plistStdout: "<key>dev-entry</key>\n<string>/dev/disk5s1</string>",
            mountPoint: mount
        ) == "/dev/disk5")
        // No device anywhere: detach by image path cannot work, so nil.
        #expect(DiskImageCancelBudget.detachTargetWhenPlistMissesDisk(
            image: image,
            plistStdout: "",
            mountPoint: mount
        ) == nil)
        #expect(DiskImageCancelBudget.detachTargetWhenPlistMissesDisk(
            image: image,
            plistStdout: mount,
            mountPoint: mount
        ) == nil)
        #expect(DiskImageCancelBudget.wholeDiskDevice("/dev/disk12s3") == "/dev/disk12")
        #expect(DiskImageCancelBudget.wholeDiskDevice("/dev/disk") == nil)
        #expect(DiskImageCancelBudget.wholeDiskDevice("/tmp/disk4") == nil)
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
        // Live clock. The copy budget above the detach reserve is armed on
        // the first byte check, and every check reads `Date()`. A short
        // sleep after the first slice spends that budget, so one chunk is
        // written and the rest of the 256KB file is not.
        var copyDeadline: Date?
        var byteChecks = 0
        let copied = copyFileLeavingDetachReserve(
            from: source.fileDescriptor,
            to: destination.fileDescriptor,
            mayContinue: { point in
                if point == .xattr { return false }
                byteChecks += 1
                if copyDeadline == nil {
                    copyDeadline = Date().addingTimeInterval(DiskImageCancelBudget.detachCap + 0.4)
                }
                if byteChecks >= 3 {
                    Thread.sleep(forTimeInterval: 0.5)
                }
                return DiskImageCancelBudget.copyMayContinue(deadline: copyDeadline, now: Date())
            },
            copyXattr: { _, _ in true }
        )
        #expect(copied == false)
        let written = try Data(contentsOf: destURL)
        #expect(written.isEmpty == false)
        #expect(written.count <= 64 * 1024)
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
        let peerNow = Date(timeIntervalSince1970: 8_000)
        #expect(diskImageAcquireSliceDeadline(
            armed: nil,
            now: peerNow,
            slice: 45,
            peerHoldsLock: true
        ) == nil)
        let armed = diskImageAcquireSliceDeadline(
            armed: nil,
            now: peerNow,
            slice: 45,
            peerHoldsLock: false
        )
        #expect(armed == peerNow.addingTimeInterval(45))
        #expect(diskImageAcquireSliceDeadline(
            armed: armed,
            now: peerNow.addingTimeInterval(30),
            slice: 45,
            peerHoldsLock: false
        ) == armed)
        #expect(diskImagePeerWaitFailsBoundary(peerHoldsLock: true, acquireSliceSpent: true) == false)
        #expect(diskImagePeerWaitFailsBoundary(
            peerHoldsLock: true,
            acquireSliceSpent: true,
            peerWaitSpent: false
        ) == false)
        #expect(diskImagePeerWaitFailsBoundary(
            peerHoldsLock: true,
            acquireSliceSpent: false,
            peerWaitSpent: true
        ))
        #expect(diskImagePeerWaitFailsBoundary(peerHoldsLock: false, acquireSliceSpent: true))
        #expect(DiskImageCancelBudget.peerAcquireWait == 120)
        #expect(DiskImageCancelBudget.peerAcquireWait > 45)
        #expect(DiskImageCancelBudget.peerAcquireWait < 30 * 60)
        #expect(DiskImageCancelBudget.peerAcquireWait != DiskImageCancelBudget.returnBound)
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
        #expect(diskImagePublicationRecheckCanClear(helperStillAlive: true, imageListed: nil) == false)
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

    /// A sibling row does not clear while this file is present, and does
    /// not clear on `ENOENT` while diskimagesd can still hold the fd. A
    /// timeout does not clear that `ENOENT` either. A parsed `images: []`
    /// does clear an image file that is actually gone. A mount path does
    /// not clear while `/dev/diskN` can still appear.
    @Test func deadHelperClearsANilListingAndKeepsASiblingListing() throws {
        let image = "/tmp/rv-inode-TOKEN.sparseimage"
        let empty = diskImageInfoListingShowsImage(
            parsedImageCount: 0,
            identity: image,
            imagePaths: []
        )
        #expect(empty == nil)
        #expect(diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: empty,
            infoTimedOut: false,
            imageFileGone: false
        ) == false)
        #expect(diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: empty,
            infoTimedOut: true,
            imageFileGone: false
        ) == false)
        #expect(diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: empty,
            infoTimedOut: true,
            imageFileGone: true
        ) == false)
        #expect(diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: empty,
            infoTimedOut: false,
            imageFileGone: true,
            listingUnparsed: true
        ) == false)
        #expect(diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: empty,
            imageFileGone: true,
            parsedImageCount: 0
        ))
        #expect(diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: nil,
            imageFileGone: true,
            parsedImageCount: 1
        ) == false)
        let unreportedMount = diskImageInfoListingShowsImage(
            parsedImageCount: 1,
            identity: "/private/var/folders/ws",
            imagePaths: ["/tmp/rv-inode-OTHER.sparseimage"],
            mountPoints: []
        )
        #expect(unreportedMount == nil)
        #expect(diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: unreportedMount,
            imageFileGone: false,
            identityIsImage: false
        ) == false)
        #expect(diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: unreportedMount,
            infoTimedOut: false,
            imageFileGone: true,
            identityIsImage: false,
            parsedImageCount: 1
        ) == false)
        #expect(diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: unreportedMount,
            infoTimedOut: false,
            imageFileGone: true,
            identityIsImage: false,
            parsedImageCount: 0
        ) == false)
        let sibling = diskImageInfoListingShowsImage(
            parsedImageCount: 1,
            identity: image,
            imagePaths: ["/tmp/rv-inode-OTHER.sparseimage"]
        )
        #expect(sibling == false)
        #expect(diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: sibling,
            imageFileGone: false
        ) == false)
        #expect(diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: false,
            imageFileGone: false
        ) == false)
        #expect(diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: sibling,
            imageFileGone: true,
            parsedImageCount: 1
        ) == false)
        #expect(diskImageMayStartHelper(
            publicationHeld: true,
            arguments: ["/usr/bin/hdiutil", "attach", "-nomount", "-plist", image]
        ) == false)
        let shown = diskImageInfoListingShowsImage(
            parsedImageCount: 1,
            identity: image,
            imagePaths: ["/private/tmp/rv-inode-TOKEN.sparseimage"]
        )
        #expect(shown == true)
        #expect(diskImagePublicationRecheckCanClear(helperStillAlive: false, imageListed: shown) == false)
        #expect(diskImagePublicationRecheckCanClear(helperStillAlive: true, imageListed: nil) == false)
        let nilStillAppears = diskImageCanStillAppear(
            helperStillAlive: false,
            detachStatus: 0,
            detachTimedOut: false,
            detachOutput: "",
            imageListedAfterDetach: nil,
            waitedForPublication: true
        )
        #expect(nilStillAppears)
        #expect(diskImagePublicationCanClear(
            helperStillAlive: false,
            diskCanStillAppear: nilStillAppears,
            imageKnown: true
        ) == false)
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
        let now = Date(timeIntervalSince1970: 50_000)
        let bound = now.addingTimeInterval(DiskImageCancelBudget.returnBound)
        let late = now.addingTimeInterval(7.74)
        let sleep = diskImageRecheckAllowance(
            budget: DiskImageCancelBudget.preemptCleanup,
            cancelDeadline: bound,
            now: late
        )
        let info = diskImageRecheckAllowance(
            budget: DiskImageCancelBudget.preemptReap,
            cancelDeadline: bound,
            now: late.addingTimeInterval(sleep)
        )
        #expect(sleep < DiskImageCancelBudget.preemptCleanup)
        #expect(late.addingTimeInterval(sleep + info) <= bound)
        #expect(diskImageRecheckAllowance(
            budget: DiskImageCancelBudget.preemptCleanup,
            cancelDeadline: nil,
            now: now
        ) == DiskImageCancelBudget.preemptCleanup)
        let armed = Date(timeIntervalSince1970: 70_000)
        let clockEnd = armed.addingTimeInterval(DiskImageCancelBudget.cancelledSequenceBudget)
        let acquired = armed.addingTimeInterval(7)
        let clippedSleep = diskImageRecheckAllowance(
            budget: DiskImageCancelBudget.preemptCleanup,
            cancelDeadline: clockEnd,
            now: acquired
        )
        let clippedInfo = diskImageRecheckAllowance(
            budget: DiskImageCancelBudget.preemptReap,
            cancelDeadline: clockEnd,
            now: acquired.addingTimeInterval(clippedSleep)
        )
        let afterInfo = acquired.addingTimeInterval(clippedSleep + clippedInfo)
        #expect(diskImageRecheckMayStat(cancelDeadline: clockEnd, now: afterInfo) == false)
        #expect(diskImageRecheckMayStat(cancelDeadline: nil, now: afterInfo))
        #expect(afterInfo <= armed.addingTimeInterval(DiskImageCancelBudget.returnBound))
        #expect(fcopyfileAttributeCopySucceeded(toolStatus: 0, statusQuit: true) == false)
        #expect(fcopyfileAttributeCopySucceeded(toolStatus: 0, statusQuit: false))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-gate-stat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let present = root.appendingPathComponent("rv-inode-TOKEN.sparseimage")
        FileManager.default.createFile(atPath: present.path, contents: Data("x".utf8))
        #expect(diskImageSparseFileIsDefinitivelyGone(present.path) == false)
        #expect(diskImageSparseFileIsDefinitivelyGone(root.appendingPathComponent("missing").path))
        #expect(diskImageMountPointIsGone(root.path) == false)
        #expect(diskImageMountPointIsGone(root.appendingPathComponent("missing-mount").path))
        #expect(diskImageMountStatIsGone(statSucceeded: false, errnoValue: EIO) == false)
        #expect(diskImageMountStatIsGone(statSucceeded: false, errnoValue: ESTALE) == false)
        #expect(diskImageMountStatIsGone(statSucceeded: false, errnoValue: EACCES) == false)
        #expect(diskImageMountStatIsGone(statSucceeded: false, errnoValue: ENOENT))
        #expect(diskImageMountStatIsGone(statSucceeded: true, errnoValue: 0) == false)
        #expect(diskImageParkedPathIsGone(present.path, identityIsImage: true) == false)
        #expect(diskImageParkedPathIsGone(root.path, identityIsImage: false) == false)
    }

    /// The detach follow-up keeps a sibling row, a pathless row, and a file
    /// that is still on disk. A stat that starts with time left stops on the
    /// cancel clock, including the shared clock when the local deadline is nil.
    @Test func detachFollowUpKeepsASiblingAndTheStatStopsOnTheClock() throws {
        let image = "/tmp/rv-inode-TOKEN.sparseimage"
        let omittedAfterWait = diskImageCanStillAppear(
            helperStillAlive: false,
            detachStatus: 0,
            detachTimedOut: false,
            detachOutput: "not currently attached",
            imageListedAfterDetach: false,
            waitedForPublication: true
        )
        #expect(omittedAfterWait == false)
        #expect(diskImageDetachFollowUpCanStillAppear(
            listingCanAppear: omittedAfterWait,
            imageListed: false,
            imageFileGone: true,
            parsedImageCount: 1
        ))
        #expect(diskImageDetachFollowUpCanStillAppear(
            listingCanAppear: omittedAfterWait,
            imageListed: false,
            imageFileGone: false,
            parsedImageCount: 1
        ))
        #expect(diskImageDetachFollowUpCanStillAppear(
            listingCanAppear: omittedAfterWait,
            imageListed: false,
            imageFileGone: false,
            parsedImageCount: 2
        ))
        let kept = diskImageSerializationExit(
            helperStillAlive: false,
            diskCanStillAppear: true,
            detachOutputContainsBusy: false
        )
        #expect(kept.mayStartNextAttach == false)
        #expect(diskImageMayRetryPreemptedHelper(
            cleanup: .detachImage(image),
            cleanupSucceeded: true,
            helperStillAlive: false,
            targetWasAbsent: false,
            diskCanStillAppear: true
        ) == false)
        #expect(diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: false,
            imageFileGone: true,
            parsedImageCount: 1
        ) == false)
        #expect(diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: false,
            identityIsImage: false
        ) == false)
        #expect(diskImageDetachFollowUpCanStillAppear(
            listingCanAppear: true,
            imageListed: nil,
            imageFileGone: true,
            parsedImageCount: 0
        ))
        let armed = Date(timeIntervalSince1970: 90_000)
        let clockEnd = armed.addingTimeInterval(DiskImageCancelBudget.cancelledSequenceBudget)
        let acquired = armed.addingTimeInterval(7)
        let sleep = diskImageRecheckAllowance(
            budget: DiskImageCancelBudget.preemptCleanup,
            cancelDeadline: clockEnd,
            now: acquired
        )
        #expect(sleep == DiskImageCancelBudget.preemptCleanup)
        let afterFastInfo = acquired.addingTimeInterval(sleep)
        let left = clockEnd.timeIntervalSince(afterFastInfo)
        #expect(diskImageRecheckStatBudget(cancelDeadline: clockEnd, now: afterFastInfo) == .limited(left))
        #expect(diskImageRecheckMayStat(cancelDeadline: clockEnd, now: afterFastInfo))
        #expect(afterFastInfo.addingTimeInterval(left) <= armed.addingTimeInterval(DiskImageCancelBudget.returnBound))
        let parked = armed.addingTimeInterval(1.5)
        let parkedLeft = clockEnd.timeIntervalSince(parked)
        #expect(diskImageRecheckStatBudget(cancelDeadline: clockEnd, now: parked) == .limited(parkedLeft))
        #expect(parked.addingTimeInterval(parkedLeft) <= armed.addingTimeInterval(DiskImageCancelBudget.returnBound))
        #expect(diskImageRecheckMayStat(
            cancelDeadline: nil,
            sharedCancelDeadline: clockEnd,
            now: clockEnd
        ) == false)
        #expect(diskImageRecheckStatBudget(cancelDeadline: nil, now: clockEnd) == .uncancelled)
        #expect(diskImageRecheckStatDeadline(local: nil, shared: clockEnd) == clockEnd)
        #expect(diskImageRecheckAllowance(
            budget: DiskImageCancelBudget.preemptCleanup,
            cancelDeadline: diskImageRecheckStatDeadline(local: nil, shared: clockEnd),
            now: clockEnd
        ) == 0)
        #expect(diskImageRecheckAllowance(
            budget: DiskImageCancelBudget.preemptCleanup,
            cancelDeadline: diskImageRecheckStatDeadline(local: nil, shared: nil),
            now: armed
        ) == DiskImageCancelBudget.preemptCleanup)
        #expect(diskImageRecheckMayStat(cancelDeadline: nil, now: armed))
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
        let skippedCalls = StatCallCount()
        #expect(diskImageWaitForStat(allowance: 0) {
            skippedCalls.value += 1
            return true
        } == nil)
        #expect(skippedCalls.value == 0)
        #expect(diskImageWaitForStat(allowance: nil) { false } == false)
        let releaseStat = StatCallCount()
        let clipped = Date()
        #expect(diskImageWaitForStat(allowance: 0.05) {
            while releaseStat.value == 0 {
                var status = stat()
                _ = "/".withCString { stat($0, &status) }
            }
            return true
        } == nil)
        #expect(releaseStat.value == 0)
        #expect(Date().timeIntervalSince(clipped) < 0.2)
        #expect(Date().timeIntervalSince(clipped) < DiskImageCancelBudget.returnBound)
        releaseStat.value = 1
        #expect(diskImageInterruptedReadMayRetry(errnoValue: EINTR, clockAllowsAnotherCall: false) == false)
        #expect(diskImageInterruptedReadMayRetry(errnoValue: EINTR, clockAllowsAnotherCall: true))
        #expect(diskImageInterruptedReadMayRetry(errnoValue: EIO, clockAllowsAnotherCall: true) == false)
        let dueCalls = StatCallCount()
        #expect(diskImageStatObservingCancelClock(
            localDeadline: nil,
            sharedDeadline: clockEnd,
            now: clockEnd
        ) {
            dueCalls.value += 1
            return true
        } == nil)
        #expect(dueCalls.value == 0)
        #expect(diskImageStatObservingCancelClock(
            localDeadline: nil,
            sharedDeadline: nil,
            now: armed
        ) { false } == false)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-detach-stat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let present = root.appendingPathComponent("rv-inode-TOKEN.sparseimage")
        FileManager.default.createFile(atPath: present.path, contents: Data("x".utf8))
        let missing = root.appendingPathComponent("rv-inode-MISSING.sparseimage").path
        #expect(diskImageDetachFollowUpFileIsGone(
            identity: present.path,
            imageListed: false,
            localDeadline: nil,
            sharedDeadline: nil
        ) == false)
        #expect(diskImageDetachFollowUpFileIsGone(
            identity: missing,
            imageListed: false,
            localDeadline: nil,
            sharedDeadline: nil
        ))
        #expect(diskImageDetachFollowUpFileIsGone(
            identity: missing,
            imageListed: false,
            localDeadline: nil,
            sharedDeadline: clockEnd,
            now: clockEnd
        ) == false)
        #expect(diskImageDetachFollowUpFileIsGone(
            identity: missing,
            imageListed: nil,
            localDeadline: nil,
            sharedDeadline: nil
        ) == false)
        #expect(diskImageDetachFollowUpCanStillAppear(
            listingCanAppear: omittedAfterWait,
            imageListed: false,
            imageFileGone: false,
            parsedImageCount: 1
        ))
    }

    /// A `stat` that keeps running does not hold the waiter. Darwin does not
    /// make `stat` return `EINTR`, so the waiter leaves at the clock and is
    /// not the thread inside `stat`. The detach keeps do not depend on that
    /// stat finishing.
    @Test func blockingCallsStopOnTheCancelClockAndLeaveTheWorker() {
        let slice = Date(timeIntervalSince1970: 100_000).addingTimeInterval(45)
        let armed = Date(timeIntervalSince1970: 100_000)
        let clockEnd = armed.addingTimeInterval(DiskImageCancelBudget.cancelledSequenceBudget)
        #expect(diskImageListedInfoBudget(
            sliceDeadline: slice,
            localDeadline: nil,
            sharedDeadline: clockEnd,
            now: clockEnd
        ) == 0)
        let atSevenFive = armed.addingTimeInterval(7.5)
        let infoLeft = diskImageListedInfoBudget(
            sliceDeadline: slice,
            localDeadline: nil,
            sharedDeadline: clockEnd,
            now: atSevenFive
        )
        #expect(infoLeft == 0.25)
        #expect(infoLeft < 1)
        #expect(atSevenFive.addingTimeInterval(infoLeft) <= armed.addingTimeInterval(DiskImageCancelBudget.returnBound))
        #expect(diskImageListedInfoBudget(
            sliceDeadline: slice,
            localDeadline: nil,
            sharedDeadline: nil,
            now: armed
        ) == 1)
        let copyAllowance = diskImageTreeSyscallAllowance(deadline: clockEnd, now: armed) ?? -1
        #expect(copyAllowance == DiskImageCancelBudget.cancelledSequenceBudget - DiskImageCancelBudget.detachCap)
        #expect(armed.addingTimeInterval(copyAllowance) <= armed.addingTimeInterval(DiskImageCancelBudget.returnBound))
        #expect(diskImageTreeSyscallAllowance(deadline: nil, now: armed) == nil)
        #expect(diskImageTreeSyscallAllowance(deadline: clockEnd, now: clockEnd) == 0)
        let treeStop = diskImageTreeCopyStop(deadline: clockEnd, now: armed)
        #expect(treeStop == armed.addingTimeInterval(copyAllowance))
        #expect(diskImageMountStatAllowance(sharedDeadline: nil, now: armed) == .uncancelled)
        #expect(diskImageMountStatAllowance(sharedDeadline: clockEnd, now: clockEnd) == .skip)
        let parked = armed.addingTimeInterval(1.5)
        #expect(diskImageMountStatAllowance(sharedDeadline: clockEnd, now: parked) == .limited(clockEnd.timeIntervalSince(parked)))
        let callerID = ObjectIdentifier(Thread.current)
        let onCaller = StatCallCount()
        let release = StatCallCount()
        let gate = DeadlineGate()
        let started = Date()
        let stopped = diskImageStatObservingCancelClock(
            localDeadline: nil,
            sharedDeadline: nil,
            liveDeadline: { gate.date }
        ) {
            if ObjectIdentifier(Thread.current) == callerID {
                onCaller.value = 1
            }
            gate.date = Date().addingTimeInterval(0.05)
            while release.value == 0 {
                var status = stat()
                _ = "/".withCString { stat($0, &status) }
            }
            return true
        }
        #expect(stopped == nil)
        #expect(onCaller.value == 0)
        #expect(release.value == 0)
        #expect(Date().timeIntervalSince(started) < 0.2)
        #expect(Date().timeIntervalSince(started) < DiskImageCancelBudget.returnBound)
        release.value = 1
        #expect(diskImageDetachFollowUpCanStillAppear(
            listingCanAppear: false,
            imageListed: false,
            imageFileGone: false,
            parsedImageCount: 1
        ))
        #expect(diskImageDetachFollowUpCanStillAppear(
            listingCanAppear: false,
            imageListed: false,
            imageFileGone: true,
            parsedImageCount: 1
        ))
        let flag = CooperativeLaunchStop.Flag()
        CooperativeLaunchStop.install(flag)
        defer { CooperativeLaunchStop.uninstall() }
        #expect(diskImageLiveCancelDeadline() == nil)
        flag.cancel()
        let live = diskImageLiveCancelDeadline()
        #expect(live != nil)
        #expect(live!.timeIntervalSinceNow < DiskImageCancelBudget.returnBound)
        #expect(live!.timeIntervalSinceNow <= DiskImageCancelBudget.cancelledSequenceBudget + 0.05)
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
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
        let (other, cleanup) = try crossDeviceRestoreDirectory(beside: temporary)
        defer { cleanup() }
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

    /// A clock stop at `ftruncate` is not a finished failure: the parked
    /// worker can still truncate. The tri-state result must say so (nil),
    /// and a finished truncate still reports true.
    @Test func ftruncateClockStopIsNotAFinishedFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-ftruncate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("saved")
        try Data(repeating: 0x41, count: 128).write(to: url)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try withSpentCopyClock {
            #expect(diskImageFtruncateWithinCopyClock(handle.fileDescriptor, 0) == nil)
        }
        #expect(try Data(contentsOf: url).count == 128)
        #expect(diskImageFtruncateWithinCopyClock(handle.fileDescriptor, 0) == true)
        #expect(try Data(contentsOf: url).count == 0)
    }

    /// An attribute larger than the copy window still copies: the get
    /// and set run whole on clocked workers instead of failing the tree.
    @Test func xattrLargerThanTheWindowStillCopies() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-xattr-large-\(UUID().uuidString)", isDirectory: true)
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
        let name = "user.rv-large"
        let value = [UInt8](repeating: 7, count: 100_000)
        try #require(writeXattr(source.fileDescriptor, name, value))
        // A stale destination-only attribute must not survive the copy.
        try #require(writeXattr(destination.fileDescriptor, "user.rv-stale", [1]))
        let copied = copyXattrsObservingClock(
            from: source.fileDescriptor,
            to: destination.fileDescriptor
        ) { true }
        #expect(copied)
        #expect(readXattr(destination.fileDescriptor, name) == value)
        #expect(readXattr(destination.fileDescriptor, "user.rv-stale") == nil)
    }

    /// A spent copy clock must not run these on the caller. `a044874d` still
    /// chmod/rmdir/unlink/rename/open/fstat/fgetxattr/fsetxattr/realpath-fallback
    /// here, so the file changes and the attribute lands. No sleep: allowance 0
    /// does not start the syscall.
    @Test func spentCopyClockDoesNotRunCallerVnodeCalls() throws {
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-clock-vnode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        let linked = target.path.withCString { targetPath in
            link.path.withCString { linkPath in
                symlink(targetPath, linkPath)
            }
        }
        #expect(linked == 0)
        let workspace = try #require(WorkingDirectory(validating: link.path))
        let resolvedWhileOpen = resolvedWorkspacePath(workspace)
        #expect(resolvedWhileOpen != link.path)

        let directory = root.appendingPathComponent("mode", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(diskImageChmodWithinCopyClock(directory.path, 0o755) == true)
        let modeBefore = try #require(posixMode(directory.path))
        #expect(modeBefore == 0o755)

        let doomed = root.appendingPathComponent("doomed", isDirectory: true)
        try FileManager.default.createDirectory(at: doomed, withIntermediateDirectories: true)
        let kept = root.appendingPathComponent("kept")
        try Data("stay".utf8).write(to: kept)
        let originalURL = root.appendingPathComponent("original")
        let backupURL = root.appendingPathComponent("backup")
        try Data("old".utf8).write(to: originalURL)
        try Data("new".utf8).write(to: backupURL)
        let backup = try FileHandle(forReadingFrom: backupURL)
        let sized = try FileHandle(forReadingFrom: originalURL)
        defer {
            try? backup.close()
            try? sized.close()
        }
        let knownSize = descriptorSize(sized.fileDescriptor)
        #expect(knownSize == 3)

        let sourceURL = root.appendingPathComponent("xsrc")
        let destURL = root.appendingPathComponent("xdst")
        FileManager.default.createFile(atPath: sourceURL.path, contents: Data("src".utf8))
        FileManager.default.createFile(atPath: destURL.path, contents: Data("dst".utf8))
        let source = try FileHandle(forUpdating: sourceURL)
        let destination = try FileHandle(forUpdating: destURL)
        defer {
            try? source.close()
            try? destination.close()
        }
        let name = "user.rv-clock"
        let value: [UInt8] = [9, 8, 7]
        #expect(writeXattr(source.fileDescriptor, name, value))

        try withSpentCopyClock {
            let allowance = diskImageTreeSyscallAllowance(
                deadline: CooperativeLaunchStop.cancelClock?.deadline
            )
            #expect(allowance == 0)
            let stopped = resolvedWorkspacePath(workspace)
            #expect(stopped == link.path)
            #expect(stopped != resolvedWhileOpen)

            #expect(diskImageChmodWithinCopyClock(directory.path, 0o700) == nil)
            #expect(diskImageRmdirWithinCopyClock(doomed.path) == nil)
            #expect(FileManager.default.fileExists(atPath: doomed.path))

            unlinkTruncatedSaved(kept.path)
            let keptBytes = try Data(contentsOf: kept)
            #expect(keptBytes == Data("stay".utf8))

            #expect(installBackupByRename(
                backupURL,
                over: originalURL.path,
                backup: backup.fileDescriptor
            ) == false)
            let afterRename = try Data(contentsOf: originalURL)
            #expect(afterRename == Data("old".utf8))
            #expect(installBackupFile(
                backupURL,
                over: originalURL.path,
                backup: backup.fileDescriptor,
                mayContinue: { _ in true }
            ) == .failed)
            let afterOpen = try Data(contentsOf: originalURL)
            #expect(afterOpen == Data("old".utf8))
            #expect(FileManager.default.fileExists(atPath: originalURL.path + ".rv-restore") == false)

            #expect(descriptorSize(sized.fileDescriptor) == nil)
            #expect(copyOneXattrObservingClock(
                from: source.fileDescriptor,
                to: destination.fileDescriptor,
                name: name,
                chunkBytes: 64,
                trace: XattrCopyTrace(),
                mayContinue: { true }
            ) == false)
            #expect(readXattrWindow(
                source.fileDescriptor,
                name,
                offset: 0,
                length: value.count
            ) == nil)
            #expect(writeXattr(destination.fileDescriptor, name, value) == false)
        }

        #expect(posixMode(directory.path) == modeBefore)
        #expect(FileManager.default.fileExists(atPath: doomed.path))
        #expect(diskImageRmdirWithinCopyClock(doomed.path) == true)
        #expect(FileManager.default.fileExists(atPath: doomed.path) == false)
        #expect(diskImageChmodWithinCopyClock(directory.path, 0o700) == true)
        #expect(posixMode(directory.path) == 0o700)
        #expect(try Data(contentsOf: kept) == Data("stay".utf8))
        #expect(try Data(contentsOf: originalURL) == Data("old".utf8))
        #expect(readXattr(destination.fileDescriptor, name) == nil)
        #expect(readXattr(source.fileDescriptor, name) == value)
        #expect(descriptorSize(sized.fileDescriptor) == knownSize)
    }

    /// Establish and reattach open the mount through
    /// `diskImageOpenPathWithinCopyClock`. A positive copy budget enters
    /// `open` of a fifo with no writer. The waiter returns nil before
    /// `returnBound`. A bare `open` of that fifo stays inside the syscall
    /// until the writer at 1.5s, then returns a descriptor, not nil.
    /// Allowance 0 never enters `open` and returns in well under a tenth of
    /// a second, so it fails `elapsed > 0.1`.
    @Test func blockedMountOpenReturnsWhileTheSyscallIsInside() throws {
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-mount-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("mount")
        let created = fifo.path.withCString { mkfifo($0, 0o600) }
        try #require(created == 0)

        let release = DispatchSemaphore(value: 0)
        let fifoPath = fifo.path
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 1.5)
            let writer = fifoPath.withCString { open($0, O_WRONLY | O_NONBLOCK | O_CLOEXEC) }
            if writer >= 0 { close(writer) }
            release.signal()
        }
        defer { release.wait() }

        let budget: TimeInterval = 0.25
        let now = Date()
        let timeLeft = DiskImageCancelBudget.detachCap + budget
        let cancelledAt = now.addingTimeInterval(
            timeLeft - DiskImageCancelBudget.cancelledSequenceBudget
        )
        let flag = CooperativeLaunchStop.Flag()
        flag.noteCancel(now: cancelledAt)
        CooperativeLaunchStop.install(flag)
        defer { CooperativeLaunchStop.uninstall() }
        let allowance = diskImageTreeSyscallAllowance(
            deadline: CooperativeLaunchStop.cancelClock?.deadline
        )
        #expect(allowance != nil)
        let granted = allowance ?? 0
        #expect(granted > 0.1)
        #expect(granted < 1)

        let started = Date()
        let opened = diskImageOpenPathWithinCopyClock(fifo.path, O_RDONLY)
        let elapsed = Date().timeIntervalSince(started)
        #expect(opened == nil)
        #expect(elapsed > 0.1)
        #expect(elapsed < DiskImageCancelBudget.returnBound)
        let writer = fifo.path.withCString { open($0, O_WRONLY | O_NONBLOCK | O_CLOEXEC) }
        if writer >= 0 { close(writer) }
        if let opened, opened >= 0 { close(opened) }
    }

    /// `removeOwnedFile` uses this. `a35644a2` `lstat`s and `unlink`s on the
    /// caller with no clock, so a spent clock still deletes the file and
    /// returns success. A stop is not gone. A different inode is left in
    /// place. A missing path is success.
    @Test func stoppedRemoveOwnedRegularIsNotGone() throws {
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-owned-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = root.appendingPathComponent("missing").path
        #expect(diskImageRemoveOwnedRegular(path: missing, device: 1, inode: 1))

        let directoryIdentity = try #require(lstatIdentity(root.path))
        #expect(diskImageRemoveOwnedRegular(
            path: root.path,
            device: directoryIdentity.device,
            inode: directoryIdentity.inode
        ))
        #expect(FileManager.default.fileExists(atPath: root.path))

        let kept = root.appendingPathComponent("kept")
        try Data("stay".utf8).write(to: kept)
        let keptIdentity = try #require(lstatIdentity(kept.path))
        #expect(diskImageRemoveOwnedRegular(
            path: kept.path,
            device: keptIdentity.device,
            inode: keptIdentity.inode &+ 1
        ))
        #expect(try Data(contentsOf: kept) == Data("stay".utf8))

        let doomed = root.appendingPathComponent("doomed")
        try Data("gone".utf8).write(to: doomed)
        let doomedIdentity = try #require(lstatIdentity(doomed.path))
        #expect(diskImageRemoveOwnedRegular(
            path: doomed.path,
            device: doomedIdentity.device,
            inode: doomedIdentity.inode
        ))
        #expect(FileManager.default.fileExists(atPath: doomed.path) == false)

        let held = root.appendingPathComponent("held")
        try Data("held".utf8).write(to: held)
        let heldIdentity = try #require(lstatIdentity(held.path))
        try withSpentCopyClock {
            #expect(diskImageRemoveOwnedRegular(
                path: held.path,
                device: heldIdentity.device,
                inode: heldIdentity.inode
            ) == false)
        }
        #expect(try Data(contentsOf: held) == Data("held".utf8))
    }

    /// `8b691cad` unlinks the staged temp file on the caller after the copy
    /// clock has already stopped the read. A stop is not gone, so the file
    /// stays. The read is a pipe with no writer: allowance 0 would return
    /// before `open`. This budget is positive, and the call does not return
    /// until that read has been entered.
    @Test func clockStopLeavesTheStagedFile() throws {
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-stage-hold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("original")
        try Data("old".utf8).write(to: originalURL)
        let original = try FileHandle(forUpdating: originalURL)
        defer { try? original.close() }
        var pair: [Int32] = [-1, -1]
        let opened = pair.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return pipe(base)
        }
        try #require(opened == 0)
        defer {
            if pair[0] >= 0 { close(pair[0]) }
            if pair[1] >= 0 { close(pair[1]) }
        }
        let before = stageNames()
        try withCopyBudget(0.25) {
            let allowance = diskImageTreeSyscallAllowance(
                deadline: CooperativeLaunchStop.cancelClock?.deadline
            )
            #expect((allowance ?? 0) > 0.1)
            #expect((allowance ?? 1) < 1)
            let started = Date()
            let outcome = replaceOriginalOnlyAfterStagedCopy(
                source: pair[0],
                original: original.fileDescriptor,
                originalPath: originalURL.path,
                mayContinue: { _ in true },
                copyXattr: { _, _ in true }
            )
            let elapsed = Date().timeIntervalSince(started)
            #expect(outcome.committed == false)
            #expect(outcome.reachedTruncate == false)
            #expect(elapsed > 0.1)
            #expect(elapsed < DiskImageCancelBudget.returnBound)
        }
        if pair[1] >= 0 {
            close(pair[1])
            pair[1] = -1
        }
        let created = stageNames().filter { before.contains($0) == false }
        #expect(created.isEmpty == false)
        for name in created {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path))
            try? FileManager.default.removeItem(at: url)
        }
        #expect(try Data(contentsOf: originalURL) == Data("old".utf8))
    }

    /// `loadSnapshot` reads through this. `8b691cad` uses `Data(contentsOf:)`,
    /// which stays inside `open` until the writer at 1.5s and then returns
    /// bytes. A positive copy budget returns nil first. Allowance 0 does not
    /// enter `open`.
    @Test func blockedPathReadReturnsBeforeTheWriter() throws {
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-path-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("snapshot")
        try #require(fifo.path.withCString { mkfifo($0, 0o600) } == 0)
        let release = DispatchSemaphore(value: 0)
        let fifoPath = fifo.path
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 1.5)
            let writer = fifoPath.withCString { open($0, O_WRONLY | O_NONBLOCK | O_CLOEXEC) }
            if writer >= 0 { close(writer) }
            release.signal()
        }
        defer { release.wait() }
        try withCopyBudget(0.25) {
            let allowance = diskImageTreeSyscallAllowance(
                deadline: CooperativeLaunchStop.cancelClock?.deadline
            )
            #expect((allowance ?? 0) > 0.1)
            let started = Date()
            let bytes = diskImageReadWholeFileWithinCopyClock(fifo.path)
            let elapsed = Date().timeIntervalSince(started)
            #expect(bytes == nil)
            #expect(elapsed > 0.1)
            #expect(elapsed < DiskImageCancelBudget.returnBound)
        }
        let writer = fifo.path.withCString { open($0, O_WRONLY | O_NONBLOCK | O_CLOEXEC) }
        if writer >= 0 { close(writer) }
    }

    /// After the copy budget is spent, the detach reserve is still on the
    /// cancel clock. Proving the mount is gone and unlinking the image use
    /// that reserve. A copy-clock `lstat` returns `.stopped` and must not
    /// be what restore uses, or a cancelled launch reports
    /// `workspaceInodeBoundaryFailed` after the volume is already down.
    @Test func detachProofRunsAfterTheCopyBudgetIsSpent() throws {
        #expect(DiskImageCancelBudget.returnBound == 8)
        #expect(DiskImageCancelBudget.detachCap == 5)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-detach-proof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let present = root.appendingPathComponent("present")
        try Data("here".utf8).write(to: present)
        let missing = root.appendingPathComponent("missing").path
        let image = root.appendingPathComponent("image")
        try Data("img".utf8).write(to: image)

        try withCopyBudget(0) {
            let allowance = diskImageTreeSyscallAllowance(
                deadline: CooperativeLaunchStop.cancelClock?.deadline
            )
            #expect(allowance == 0)
            let full = CooperativeLaunchStop.cancelClock?.deadline?.timeIntervalSinceNow ?? 0
            #expect(full > 1)
            #expect(full <= DiskImageCancelBudget.detachCap + 0.05)

            if case .stopped = diskImageObservePath(present.path) {
            } else {
                Issue.record("copy-clock lstat must not start once the copy budget is spent")
            }
            #expect(diskImagePathExists(missing) == nil)
            #expect(diskImageUnlinkWithinCopyClock(image.path) == nil)
            #expect(FileManager.default.fileExists(atPath: image.path))

            guard case .value(let snapshot) = diskImageObservePathWithinCancelClock(present.path) else {
                Issue.record("detach proof must lstat during the detach reserve")
                return
            }
            let identity = try #require(lstatIdentity(present.path))
            #expect(snapshot.device == identity.device)
            #expect(snapshot.inode == identity.inode)
            #expect(diskImagePathExistsWithinCancelClock(missing) == false)
            #expect(diskImagePathExistsWithinCancelClock(present.path) == true)
            #expect(diskImageUnlinkWithinCancelClock(image.path) == true)
            #expect(FileManager.default.fileExists(atPath: image.path) == false)
        }
    }
}

private func stageNames() -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(
        atPath: FileManager.default.temporaryDirectory.path
    )) ?? []
    return Set(names.filter { $0.hasPrefix("rv-stage-") })
}

private func withCopyBudget(_ budget: TimeInterval, _ body: () throws -> Void) rethrows {
    let now = Date()
    let timeLeft = DiskImageCancelBudget.detachCap + budget
    let cancelledAt = now.addingTimeInterval(
        timeLeft - DiskImageCancelBudget.cancelledSequenceBudget
    )
    let flag = CooperativeLaunchStop.Flag()
    flag.noteCancel(now: cancelledAt)
    CooperativeLaunchStop.install(flag)
    defer { CooperativeLaunchStop.uninstall() }
    try body()
}

private func withSpentCopyClock(_ body: () throws -> Void) rethrows {
    let flag = CooperativeLaunchStop.Flag()
    flag.noteCancel(now: Date().addingTimeInterval(-100))
    CooperativeLaunchStop.install(flag)
    defer { CooperativeLaunchStop.uninstall() }
    try body()
}

private func posixMode(_ path: String) -> mode_t? {
    var status = stat()
    guard path.withCString({ lstat($0, &status) == 0 }) else { return nil }
    return status.st_mode & 0o777
}

private func lstatIdentity(_ path: String) -> (device: UInt64, inode: UInt64)? {
    var status = stat()
    guard path.withCString({ lstat($0, &status) == 0 }) else { return nil }
    return (UInt64(status.st_dev), UInt64(status.st_ino))
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
    // Publish uses the 64KB window. The value fits in that window, so one
    // get returns all of it while the budget remains. The detach reserve
    // is read again immediately before the set. A smaller window that fails
    // with ERANGE is not this test.
    let value = [UInt8](repeating: 3, count: 3_000)
    let chunk = 64 * 1024
    let wrote = writeXattr(source.fileDescriptor, name, value)
    #expect(wrote)
    if wrote {
        let trace = XattrCopyTrace()
        var checks = 0
        var deadline: Date?
        let started = Date()
        let copied = copyOneXattrObservingClock(
            from: source.fileDescriptor,
            to: destination.fileDescriptor,
            name: name,
            chunkBytes: chunk,
            trace: trace
        ) {
            checks += 1
            if deadline == nil {
                deadline = Date().addingTimeInterval(DiskImageCancelBudget.detachCap + 0.25)
            }
            // The get's checks stay inside the budget. The check on the
            // set itself spends the detach reserve.
            if checks >= 4 {
                Thread.sleep(forTimeInterval: 0.35)
            }
            return DiskImageCancelBudget.copyMayContinue(deadline: deadline, now: Date())
        }
        #expect(copied == false)
        #expect(checks >= 4)
        #expect(trace.largestRead == value.count)
        #expect(trace.largestWrite == 0)
        let landed = readXattr(destination.fileDescriptor, name)?.count ?? 0
        #expect(landed == 0)
        #expect(landed < value.count)
        #expect(landed != value.count)
        #expect(Date().timeIntervalSince(started) < DiskImageCancelBudget.returnBound)
    }
    #expect(namedForkCopyStarts(pathResolved: false) == false)
    #expect(namedForkCopyStarts(pathResolved: true))
    var walked = 0
    let stopped = copyXattrBytesObservingClock(byteCount: 192 * 1024, chunkBytes: 64 * 1024) {
        walked += 1
        return walked < 2
    }
    #expect(stopped == false)
    #expect(walked >= 1)
    #if canImport(Darwin)
    let forkBytes = 192 * 1024
    let forkPayload = Data(repeating: 9, count: forkBytes)
    let forkPath = sourceURL.path + "/..namedfork/rsrc"
    let forkFD = forkPath.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600)) }
    #expect(forkFD >= 0)
    if forkFD >= 0 {
        defer { close(forkFD) }
        var offset = 0
        let raw = Array(forkPayload)
        while offset < raw.count {
            let wrote = raw.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return write(forkFD, base + offset, raw.count - offset)
            }
            if wrote <= 0 { break }
            offset += wrote
        }
        #expect(offset == forkBytes)
    }
    let forkTrace = XattrCopyTrace()
    let slice = 64 * 1024
    var fcopyChecks = 0
    let fcopyDeadline = Date().addingTimeInterval(DiskImageCancelBudget.detachCap + 0.2)
    let fcopy = copyXattrsWithFcopyfile(
        from: source.fileDescriptor,
        to: destination.fileDescriptor,
        trace: forkTrace
    ) {
        fcopyChecks += 1
        if fcopyChecks == 1 {
            return DiskImageCancelBudget.copyMayContinue(deadline: fcopyDeadline, now: Date())
        }
        // The status callback runs before `fsetxattr`. Spending the
        // reserve there must quit instead of writing the attribute.
        // Later checks are the named-fork slices.
        if fcopyChecks == 2 {
            Thread.sleep(forTimeInterval: 0.3)
            return DiskImageCancelBudget.copyMayContinue(deadline: fcopyDeadline, now: Date())
        }
        return namedForkByteCount(destURL.path) < slice
    }
    #expect(fcopy == false)
    #expect(forkTrace.fcopyfileInvoked)
    let forkLanded = namedForkByteCount(destURL.path)
    #expect(forkLanded > 0)
    #expect(forkLanded < forkBytes)
    #expect(forkTrace.forkBytesWritten > 0)
    #expect(forkTrace.forkBytesWritten < forkBytes)
    let attribute = readXattr(destination.fileDescriptor, name)?.count ?? 0
    #expect(attribute < value.count)
    #expect(attribute != value.count)
    try assertFcopyfileQuitAndPreSetClockDoNotWriteTheAttribute(name: name, value: value)
    #endif
}

#if canImport(Darwin)
private func assertFcopyfileQuitAndPreSetClockDoNotWriteTheAttribute(name: String, value: [UInt8]) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-fcopy-clock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("source")
    let quitDestURL = root.appendingPathComponent("quit")
    let startDestURL = root.appendingPathComponent("start")
    FileManager.default.createFile(atPath: sourceURL.path, contents: Data("src".utf8))
    FileManager.default.createFile(atPath: quitDestURL.path, contents: Data("dst".utf8))
    FileManager.default.createFile(atPath: startDestURL.path, contents: Data("dst".utf8))
    let source = try FileHandle(forUpdating: sourceURL)
    let quitDest = try FileHandle(forUpdating: quitDestURL)
    let startDest = try FileHandle(forUpdating: startDestURL)
    defer {
        try? source.close()
        try? quitDest.close()
        try? startDest.close()
    }
    #expect(writeXattr(source.fileDescriptor, name, value))
    var quitChecks = 0
    let quitCopy = copyXattrsWithFcopyfile(
        from: source.fileDescriptor,
        to: quitDest.fileDescriptor
    ) {
        quitChecks += 1
        return quitChecks == 1
    }
    #expect(quitCopy == false)
    #expect(quitChecks == 2)
    let quitLanded = readXattr(quitDest.fileDescriptor, name)?.count ?? 0
    #expect(quitLanded == 0)
    #expect(quitLanded != value.count)
    var startChecks = 0
    var deadline: Date?
    let started = Date()
    let startCopy = copyXattrsWithFcopyfile(
        from: source.fileDescriptor,
        to: startDest.fileDescriptor
    ) {
        startChecks += 1
        if deadline == nil {
            deadline = Date().addingTimeInterval(DiskImageCancelBudget.detachCap + 0.25)
        }
        // The wrapper and `COPYFILE_START` stay inside the budget.
        // The check immediately before the set spends the reserve.
        if startChecks >= 6 {
            Thread.sleep(forTimeInterval: 0.35)
        }
        return DiskImageCancelBudget.copyMayContinue(deadline: deadline, now: Date())
    }
    #expect(startCopy == false)
    #expect(startChecks >= 6)
    let startLanded = readXattr(startDest.fileDescriptor, name)?.count ?? 0
    #expect(startLanded < value.count)
    #expect(startLanded != value.count)
    #expect(Date().timeIntervalSince(started) < DiskImageCancelBudget.returnBound)
}
#endif

#if canImport(Darwin)
private func namedForkByteCount(_ path: String) -> Int {
    let fork = path + "/..namedfork/rsrc"
    let fd = fork.withCString { open($0, O_RDONLY | O_CLOEXEC) }
    if fd < 0 { return 0 }
    defer { close(fd) }
    return Int(descriptorSize(fd) ?? 0)
}
#endif

/// A directory on a different device from `base`. macOS attaches a small
/// disk image, because that runner cannot write `/dev/shm`. Linux uses a
/// writable mount that is already a different device, and only then the
/// tmpfs at `/dev/shm`.
private func crossDeviceRestoreDirectory(beside base: URL) throws -> (URL, () -> Void) {
    #if canImport(Darwin)
    return try attachedCrossDeviceVolume(beside: base)
    #else
    if let found = writableMountDifferentDevice(from: base) {
        return found
    }
    let shm = URL(fileURLWithPath: "/dev/shm", isDirectory: true)
        .appendingPathComponent("rv-restore-exdev-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: shm, withIntermediateDirectories: true)
    return (shm, { try? FileManager.default.removeItem(at: shm) })
    #endif
}

private func deviceNumber(_ path: String) -> UInt64? {
    var status = stat()
    guard path.withCString({ stat($0, &status) }) == 0 else { return nil }
    return UInt64(status.st_dev)
}

#if canImport(Darwin)
private func attachedCrossDeviceVolume(beside base: URL) throws -> (URL, () -> Void) {
    let root = base.appendingPathComponent("rv-exdev-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let image = root.appendingPathComponent("volume.dmg")
    let mount = root.appendingPathComponent("mnt")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let created = commandStatus([
        "/usr/bin/hdiutil", "create", "-size", "8m", "-fs", "HFS+",
        "-volname", "rvexdev", "-type", "UDIF", "-quiet", image.path,
    ])
    guard created == 0 else {
        try? FileManager.default.removeItem(at: root)
        throw CocoaError(.fileWriteUnknown)
    }
    let attached = commandStatus([
        "/usr/bin/hdiutil", "attach", "-nobrowse", "-mountpoint", mount.path, "-quiet", image.path,
    ])
    guard attached == 0 else {
        try? FileManager.default.removeItem(at: root)
        throw CocoaError(.fileWriteUnknown)
    }
    return (mount, {
        _ = commandStatus(["/usr/bin/hdiutil", "detach", "-force", "-quiet", mount.path])
        try? FileManager.default.removeItem(at: root)
    })
}

private func commandStatus(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = Array(arguments.dropFirst())
    let sink = Pipe()
    process.standardOutput = sink
    process.standardError = sink
    do {
        try process.run()
    } catch {
        return 1
    }
    process.waitUntilExit()
    return process.terminationStatus
}
#else
private func writableMountDifferentDevice(from base: URL) -> (URL, () -> Void)? {
    guard let baseDevice = deviceNumber(base.path) else { return nil }
    guard let text = try? String(contentsOfFile: "/proc/mounts", encoding: .utf8) else { return nil }
    var points: [String] = []
    for line in text.split(separator: "\n") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { continue }
        let point = String(fields[1]).replacingOccurrences(of: "\\040", with: " ")
        if point == "/dev/shm" || point.hasPrefix("/dev/shm/") { continue }
        points.append(point)
    }
    for point in points {
        guard let device = deviceNumber(point), device != baseDevice else { continue }
        let url = URL(fileURLWithPath: point, isDirectory: true)
            .appendingPathComponent("rv-restore-exdev-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return (url, { try? FileManager.default.removeItem(at: url) })
        } catch {
            continue
        }
    }
    return nil
}
#endif
