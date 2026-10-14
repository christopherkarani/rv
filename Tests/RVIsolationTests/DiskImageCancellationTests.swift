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
}
