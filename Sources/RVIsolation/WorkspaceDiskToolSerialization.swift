#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization

struct ToolOutput {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
    var helperStillAlive = false

    init(
        status: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool = false,
        helperStillAlive: Bool = false
    ) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.helperStillAlive = helperStillAlive
    }
}

enum DiskImageAttempt {
    case done(ToolOutput)
    case yielded
}

/// One diskimage helper at a time. Parallel `hdiutil`/`mount_hfs` calls
/// pile onto diskimagesd until it stops answering; each waiter then sits
/// through its deadline and the F-M shard hits the job cap. The lock is
/// only around the helper, not the contained command.
///
/// A cancelled teardown does not sit out that wait. Non-urgent holders
/// abort when a cancelled caller is queued. The lock stays held until
/// the aborted helper has exited and a preempted attach or mount has
/// been detached or unmounted, so the next helper cannot start on top
/// of a parked process or a leaked device. Lock-wait time counts toward
/// the caller's deadline. The cancelled detach path's own deadlines stay
/// inside the 8-second return bound (`DiskImageCancelBudget`).
enum DiskImageToolSerialization {
    static let lock = Mutex<UInt8>(0)
    private static let priority = Mutex<DiskImagePriority>(DiskImagePriority())

    static func contains(_ path: String) -> Bool {
        path == "/usr/bin/hdiutil" || path == "/sbin/mount_hfs" || path == "/sbin/umount"
    }

    static func notePriorityWaiter() {
        priority.withLock { $0.waiters += 1 }
    }

    static func endPriorityWaiter() {
        priority.withLock { state in
            if state.waiters > 0 { state.waiters -= 1 }
        }
    }

    static func beginHolding(urgent: Bool) {
        priority.withLock { $0.urgent = urgent }
    }

    static func endHolding() {
        priority.withLock { $0.urgent = false }
    }

    /// True when another cancelled teardown is queued. Urgent holders yield
    /// too, unless this acquire was granted a turn (`yieldsToWaiter`).
    /// Otherwise a second `detachCancelledVolume` gives up while the first
    /// still holds the lock and leaves its volume mounted.
    static func hasPriorityWaiter() -> Bool {
        waiterCount() > 0
    }

    static func waiterCount() -> Int {
        priority.withLock { $0.waiters }
    }

    private static let publication = Mutex<PublicationGate>(PublicationGate())

    static func publicationGateHeld() -> Bool {
        publication.withLock { $0.held }
    }

    static func notePublicationGate(
        _ plan: PreemptedDiskHelperCleanup,
        helperStillAlive: Bool,
        diskCanStillAppear: Bool,
        busy: Bool,
        pid: pid_t
    ) {
        let parked = publication.withLock { $0 }
        let parkedAlive = parkedHelperIsAlive(parked.pid)
        let held = diskImagePublicationGateUpdate(
            plan: plan,
            helperStillAlive: helperStillAlive,
            diskCanStillAppear: diskCanStillAppear,
            busy: busy,
            parkedHelperStillAlive: parkedAlive,
            parkedDiskCanStillAppear: parked.held && parkedAlive,
            publicationAlreadyHeld: parked.held
        )
        let keep = diskImagePublicationHoldAfterUpdate(
            updateKeepsHold: held,
            planHasImage: diskImagePublicationImage(plan) != nil,
            parkedImageKnown: parked.image?.isEmpty == false,
            helperStillAlive: helperStillAlive || parkedAlive,
            diskCanStillAppear: diskCanStillAppear
        )
        publication.withLock { state in
            if keep {
                state.held = true
                if let image = diskImagePublicationImage(plan) { state.image = image }
                if pid > 1 { state.pid = pid }
            } else {
                state.held = false
                state.image = nil
                state.pid = 0
            }
        }
    }

    /// One bounded recheck once the helper is dead. The 0.5s sleep, the
    /// 0.25s info, and the stat are clipped to the cancel clock, including
    /// the shared clock `Flag.cancel()` armed while this acquire's deadline
    /// is still nil. A stat that starts with time left stops when that
    /// clock is due, so it does not return past `returnBound`. A zero info
    /// budget returns before `hdiutil info` and before the stat. A sibling
    /// row and an info timeout do not clear on `ENOENT`. A parsed
    /// `images: []` can. This does not spin until the 30-minute cap.
    static func clearPublicationGateIfDiskIsGone(clock: DiskImageCancelClock) {
        let parked = publication.withLock { $0 }
        guard parked.held else { return }
        let helperAlive = parkedHelperIsAlive(parked.pid)
        guard let image = parked.image, image.isEmpty == false else {
            guard diskImagePublicationCanClear(
                helperStillAlive: helperAlive,
                diskCanStillAppear: false,
                imageKnown: false
            ) else { return }
            publication.withLock { state in
                let stillNoImage = state.image == nil || state.image?.isEmpty == true
                let alive = parkedHelperIsAlive(state.pid)
                guard state.held, stillNoImage, alive == false else { return }
                state.held = false
                state.image = nil
                state.pid = 0
            }
            return
        }
        if helperAlive { return }
        let cleanup = diskImageRecheckAllowance(
            budget: DiskImageCancelBudget.preemptCleanup,
            cancelDeadline: diskImageRecheckStatDeadline(
                local: clock.deadline,
                shared: CooperativeLaunchStop.cancelClock?.deadline
            ),
            now: Date()
        )
        if cleanup > 0 {
            usleep(UInt32(cleanup * 1_000_000))
        }
        let infoBudget = diskImageRecheckAllowance(
            budget: DiskImageCancelBudget.preemptReap,
            cancelDeadline: diskImageRecheckStatDeadline(
                local: clock.deadline,
                shared: CooperativeLaunchStop.cancelClock?.deadline
            ),
            now: Date()
        )
        guard infoBudget > 0 else { return }
        let deadline = Date().addingTimeInterval(infoBudget)
        let listed = workspaceImageListed(image, returnDeadline: deadline, clock: clock)
        let identityIsImage = image.contains("rv-inode-") && image.hasSuffix(".sparseimage")
        guard let parkedGone = diskImageStatObservingCancelClock(
            localDeadline: clock.deadline,
            sharedDeadline: CooperativeLaunchStop.cancelClock?.deadline,
            stat: {
                identityIsImage
                    ? diskImageParkedPathIsGone(image, identityIsImage: true)
                    : diskImageMountIsNotMounted(image)
            }
        ) else { return }
        guard diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: listed.imageListed,
            infoTimedOut: listed.infoTimedOut,
            imageFileGone: identityIsImage ? parkedGone : false,
            identityIsImage: identityIsImage,
            listingUnparsed: listed.listingUnparsed,
            parsedImageCount: listed.parsedImageCount,
            waitedForPublication: cleanup >= DiskImageCancelBudget.preemptCleanup,
            mountNotMounted: identityIsImage ? false : parkedGone
        ) else { return }
        publication.withLock { state in
            guard let current = state.image, diskImageSamePath(current, image) else { return }
            let alive = parkedHelperIsAlive(state.pid)
            guard alive == false else { return }
            state.held = false
            state.image = nil
            state.pid = 0
        }
    }
}

final class DiskImageArmedSlice: @unchecked Sendable {
    var deadline: Date?
}

private struct PublicationGate: Sendable {
    var held = false
    var image: String?
    var pid: pid_t = 0
}

func diskImagePublicationImage(_ plan: PreemptedDiskHelperCleanup) -> String? {
    switch plan {
    case .unlinkSparseImage(let path), .detachImage(let path), .unmount(let path):
        return path
    case .none:
        return nil
    }
}

private struct DiskImagePriority: Sendable {
    var waiters = 0
    var urgent = false
}

private func diskDevice(in text: String) -> String? {
    text.split(whereSeparator: \.isWhitespace).map(String.init).first { $0.hasPrefix("/dev/disk") }
}

/// The mountable HFS slice from a `-nomount` attach plist: the entity
/// whose content hint is Apple_HFS, or the sole partition when hints are
/// absent (images rv creates carry exactly one volume).
func hfsSliceDevice(inPlist stdout: String) -> String? {
    guard let entities = systemEntities(inPlist: stdout) else { return nil }
    let devices: [(device: String, hint: String?)] = entities.compactMap { entity in
        guard let device = entity["dev-entry"]?.string else { return nil }
        return (device, entity["content-hint"]?.string)
    }
    if let hfs = devices.first(where: { $0.hint == "Apple_HFS" }) {
        return hfs.device
    }
    let partitions = devices.dropFirst().map(\.device)
    return partitions.count == 1 ? partitions.first : nil
}
#endif
