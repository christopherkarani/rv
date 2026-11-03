#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization

/// Tears a workspace disk down without asking DiskArbitration to unmount.
/// Arbitration-mediated unmounts wedge when diskarbitrationd is
/// unresponsive (after which `hdiutil detach` fails "Resource busy"),
/// while a direct `umount` completes in milliseconds and detaching the
/// bare disk afterwards succeeds.
@discardableResult
func detachWorkspaceDisk(_ disk: String, mountPoint: String?) -> Bool {
    let clock = CooperativeLaunchStop.adoptCancelClock(DiskImageCancelClock())
    clock.armIfWorkCancelled()
    if let mountPoint {
        let plain = clock.deadline == nil
            ? nil
            : min(DiskImageCancelBudget.cancelledDetachHelpers().plainUnmount, clock.remaining)
        unmountDirect(
            mountPoint,
            onlySource: disk,
            plainDeadline: plain,
            forceDeadline: clock.deadline == nil ? nil : cancelledForceUnmountBudget(clock),
            clock: clock
        )
    }
    if clock.deadline != nil || blockingWorkIsCancelled() {
        clock.armWithSpentSinceCancel()
        let detachLeft = min(DiskImageCancelBudget.detachCap, clock.remaining)
        if detachLeft <= 0 { return false }
        let cancelledDetach = runTool(
            ["/usr/bin/hdiutil", "detach", "-force", "-quiet", disk],
            honorCancellation: false,
            deadline: detachLeft,
            clock: clock
        )
        return DiskImageCancelBudget.preemptCleanupSucceeded(
            status: cancelledDetach.status,
            timedOut: cancelledDetach.timedOut
        )
    }
    let detached = runTool(
        ["/usr/bin/hdiutil", "detach", "-force", "-quiet", disk],
        honorCancellation: false,
        clock: clock
    )
    return DiskImageCancelBudget.preemptCleanupSucceeded(
        status: detached.status,
        timedOut: detached.timedOut
    )
}

func unlinkImageIfDetached(_ image: String?, detachSucceeded: Bool) {
    guard let image, diskImageMayRemoveImage(detachSucceeded: detachSucceeded) else { return }
    _ = diskImageUnlinkWithinCopyClock(image)
}

/// File-level so `detachWorkspaceDisk` uses the same 0.5s force slice
/// `cancelledSequenceBudget` counts. `remaining - 1` let one holder
/// occupy the lock until the other teardown's clock expired.
private func cancelledForceUnmountBudget(_ clock: DiskImageCancelClock) -> TimeInterval {
    DiskImageCancelBudget.cancelledForceSlice(remaining: clock.remaining)
}

/// Direct `umount` of our own volume. Only runs when the mountpoint's
/// statfs source is our disk, so a reused path never unmounts a foreign
/// volume. Plain unmount first; forced only while our source is still
/// mounted (open descriptors make the plain call fail busy).
func unmountDirect(
    _ mountPoint: String,
    onlySource disk: String,
    plainDeadline: TimeInterval? = nil,
    forceDeadline: TimeInterval? = nil,
    clock: DiskImageCancelClock = DiskImageCancelClock()
) {
    func isOurs(_ source: String?) -> Bool {
        guard let source else { return false }
        return source == disk || source.hasPrefix(disk + "s")
    }
    guard isOurs(workspaceMountSource(mountPoint)) else { return }
    _ = runTool(
        ["/sbin/umount", mountPoint],
        honorCancellation: false,
        deadline: plainDeadline,
        clock: clock
    )
    guard isOurs(workspaceMountSource(mountPoint)) else { return }
    let force = clock.deadline == nil ? forceDeadline : cancelledForceUnmountBudget(clock)
    if clock.deadline != nil, (force ?? 0) <= 0 { return }
    _ = runTool(
        ["/sbin/umount", "-f", mountPoint],
        honorCancellation: false,
        deadline: force,
        clock: clock
    )
}

struct PreemptCleanupOutcome {
    var succeeded: Bool
    var targetWasAbsent: Bool
    var busy: Bool
    var diskCanStillAppear: Bool
    var waitedForPublication: Bool
}

/// Runs inside `DiskImageToolSerialization.lock`. Unlink is immediate.
/// A follow-up detach or unmount uses `runToolBody` directly so it does
/// not take the lock again. Success is exit 0 before the deadline. The
/// reap after SIGKILL is bounded by `returnDeadline`. The follow-up stays
/// on this helper's own image or mount.
@discardableResult
func applyPreemptCleanup(
    _ plan: PreemptedDiskHelperCleanup,
    returnDeadline: Date,
    clock: DiskImageCancelClock,
    helperCanStillPublish: Bool,
    waitedForPublication: Bool = false
) -> PreemptCleanupOutcome {
    guard diskImageCleanupConfinedToCaller(plan) else {
        return PreemptCleanupOutcome(
            succeeded: false,
            targetWasAbsent: false,
            busy: false,
            diskCanStillAppear: true,
            waitedForPublication: waitedForPublication
        )
    }
    switch plan {
    case .none:
        return PreemptCleanupOutcome(
            succeeded: true,
            targetWasAbsent: false,
            busy: false,
            diskCanStillAppear: false,
            waitedForPublication: true
        )
    case .unlinkSparseImage(let path):
        // Create does not publish a disk. A helper that is still running
        // can. Leave the file until that helper has exited.
        guard diskImageMayUnlinkPublishedImage(
            helperStillAlive: helperCanStillPublish,
            detachSucceeded: true,
            diskCanStillAppear: false
        ) else {
            return PreemptCleanupOutcome(
                succeeded: false,
                targetWasAbsent: false,
                busy: false,
                diskCanStillAppear: helperCanStillPublish,
                waitedForPublication: waitedForPublication
            )
        }
        guard diskImageUnlinkWithinCopyClock(path) != nil else {
            return PreemptCleanupOutcome(
                succeeded: false,
                targetWasAbsent: false,
                busy: false,
                diskCanStillAppear: true,
                waitedForPublication: waitedForPublication
            )
        }
        return PreemptCleanupOutcome(
            succeeded: true,
            targetWasAbsent: false,
            busy: false,
            diskCanStillAppear: false,
            waitedForPublication: true
        )
    case .detachImage(let image):
        return detachPublishedTarget(
            plan,
            identity: image,
            returnDeadline: returnDeadline,
            clock: clock,
            helperCanStillPublish: helperCanStillPublish,
            waitedForPublication: waitedForPublication
        )
    case .unmount(let mount):
        return detachPublishedTarget(
            plan,
            identity: mount,
            returnDeadline: returnDeadline,
            clock: clock,
            helperCanStillPublish: helperCanStillPublish,
            waitedForPublication: waitedForPublication
        )
    }
}

private func detachPublishedTarget(
    _ plan: PreemptedDiskHelperCleanup,
    identity: String,
    returnDeadline: Date,
    clock: DiskImageCancelClock,
    helperCanStillPublish: Bool,
    waitedForPublication: Bool
) -> PreemptCleanupOutcome {
    // The original helper can still publish. Do not detach or unmount
    // until it has exited.
    if helperCanStillPublish {
        return PreemptCleanupOutcome(
            succeeded: false,
            targetWasAbsent: false,
            busy: false,
            diskCanStillAppear: true,
            waitedForPublication: false
        )
    }
    let follow: [String]?
    if case .detachImage(let image) = plan {
        // Detach takes the published devname, never the image path.
        switch workspaceImageDevice(image, returnDeadline: returnDeadline, clock: clock) {
        case .device(let device):
            follow = DiskImageCancelBudget.detachArguments(device: device)
        case .absent:
            return PreemptCleanupOutcome(
                succeeded: false,
                targetWasAbsent: true,
                busy: false,
                diskCanStillAppear: false,
                waitedForPublication: waitedForPublication
            )
        case .unknown:
            follow = nil
        }
    } else {
        follow = plan.followUpArguments
    }
    guard let follow else {
        return PreemptCleanupOutcome(
            succeeded: false,
            targetWasAbsent: false,
            busy: false,
            diskCanStillAppear: true,
            waitedForPublication: waitedForPublication
        )
    }
    let ran = runToolBody(
        follow,
        honorCancellation: false,
        deadline: min(DiskImageCancelBudget.preemptCleanup, max(0, returnDeadline.timeIntervalSinceNow)),
        yieldToPriorityWaiter: false,
        parkIfStuck: false,
        returnDeadline: returnDeadline,
        clock: clock
    )
    let output = ran.output.stderr + "\n" + ran.output.stdout
    if ran.helperStillAlive {
        return PreemptCleanupOutcome(
            succeeded: false,
            targetWasAbsent: false,
            busy: false,
            diskCanStillAppear: true,
            waitedForPublication: false
        )
    }
    let busy = diskImageDetachIsBusy(
        status: ran.output.status,
        timedOut: ran.output.timedOut,
        output: output
    )
    let absent = diskImageCleanupTargetWasAbsent(
        status: ran.output.status,
        timedOut: ran.output.timedOut,
        output: output
    )
    let read: DiskImageListingRead
    if busy {
        read = DiskImageListingRead(imageListed: true, infoTimedOut: false)
    } else {
        read = workspaceImageListed(
            identity,
            returnDeadline: returnDeadline,
            clock: clock
        )
    }
    let listingCanAppear = diskImageCanStillAppear(
        helperStillAlive: ran.helperStillAlive,
        detachStatus: ran.output.status,
        detachTimedOut: ran.output.timedOut,
        detachOutput: output,
        imageListedAfterDetach: read.imageListed,
        waitedForPublication: waitedForPublication
    )
    let imageFileGone = diskImageDetachFollowUpFileIsGone(
        identity: identity,
        imageListed: read.imageListed,
        localDeadline: clock.deadline,
        sharedDeadline: CooperativeLaunchStop.cancelClock?.deadline
    )
    let canAppear = diskImageDetachFollowUpCanStillAppear(
        listingCanAppear: listingCanAppear,
        imageListed: read.imageListed,
        imageFileGone: imageFileGone,
        parsedImageCount: read.parsedImageCount
    )
    let detachOK = DiskImageCancelBudget.preemptCleanupSucceeded(
        status: ran.output.status,
        timedOut: ran.output.timedOut
    )
    let finished = diskImageMayUnlinkPublishedImage(
        helperStillAlive: ran.helperStillAlive,
        detachSucceeded: detachOK,
        diskCanStillAppear: canAppear
    )
    return PreemptCleanupOutcome(
        succeeded: finished,
        targetWasAbsent: absent && canAppear == false,
        busy: busy,
        diskCanStillAppear: canAppear,
        waitedForPublication: waitedForPublication
    )
}

struct DiskImageListingRead: Equatable, Sendable {
    var imageListed: Bool?
    var infoTimedOut: Bool
    /// `hdiutil info` exited 0 but the plist did not parse. Not `images: []`.
    var listingUnparsed: Bool = false
    /// Entries in the plist `images` array, including a row with no
    /// `image-path`. Zero is a successful empty listing.
    var parsedImageCount: Int = 0
}

/// `hdiutil info` for one image. A timeout is not an empty listing.
/// Already inside the serialization lock, so this uses `runToolBody`.
func workspaceImageListed(
    _ image: String,
    returnDeadline: Date,
    clock: DiskImageCancelClock
) -> DiskImageListingRead {
    let infoBudget = diskImageListedInfoBudget(
        sliceDeadline: returnDeadline,
        localDeadline: clock.deadline,
        sharedDeadline: CooperativeLaunchStop.cancelClock?.deadline
    )
    if infoBudget <= 0 {
        return DiskImageListingRead(imageListed: nil, infoTimedOut: true)
    }
    let info = runToolBody(
        ["/usr/bin/hdiutil", "info", "-plist"],
        honorCancellation: false,
        deadline: infoBudget,
        yieldToPriorityWaiter: false,
        parkIfStuck: false,
        returnDeadline: returnDeadline,
        clock: clock
    )
    if info.helperStillAlive || info.output.timedOut || info.output.status != 0 {
        return DiskImageListingRead(imageListed: nil, infoTimedOut: true)
    }
    guard let data = info.output.stdout.data(using: .utf8),
        let images = AttachedWorkspaceImage.parse(hdiutilInfo: data),
        let rawCount = AttachedWorkspaceImage.listedImageCount(hdiutilInfo: data)
    else {
        return DiskImageListingRead(imageListed: nil, infoTimedOut: false, listingUnparsed: true)
    }
    return DiskImageListingRead(
        imageListed: diskImageInfoListingShowsImage(
            parsedImageCount: rawCount,
            identity: image,
            imagePaths: images.map(\.imagePath),
            mountPoints: images.compactMap(\.mountPoint)
        ),
        infoTimedOut: false,
        parsedImageCount: rawCount
    )
}

private enum WorkspaceImageDevice {
    case device(String)
    /// A parsed listing that does not contain the image.
    case absent
    case unknown
}

/// The whole-disk device `hdiutil info` currently publishes for `image`.
/// `hdiutil detach` needs that devname; the image path is not accepted.
private func workspaceImageDevice(
    _ image: String,
    returnDeadline: Date,
    clock: DiskImageCancelClock
) -> WorkspaceImageDevice {
    let infoBudget = diskImageListedInfoBudget(
        sliceDeadline: returnDeadline,
        localDeadline: clock.deadline,
        sharedDeadline: CooperativeLaunchStop.cancelClock?.deadline
    )
    guard infoBudget > 0 else { return .unknown }
    let info = runToolBody(
        ["/usr/bin/hdiutil", "info", "-plist"],
        honorCancellation: false,
        deadline: infoBudget,
        yieldToPriorityWaiter: false,
        parkIfStuck: false,
        returnDeadline: returnDeadline,
        clock: clock
    )
    if info.helperStillAlive || info.output.timedOut || info.output.status != 0 {
        return .unknown
    }
    guard let data = info.output.stdout.data(using: .utf8),
        let images = AttachedWorkspaceImage.parse(hdiutilInfo: data),
        let rawCount = AttachedWorkspaceImage.listedImageCount(hdiutilInfo: data)
    else {
        return .unknown
    }
    guard let match = images.first(where: { diskImageSamePath($0.imagePath, image) }) else {
        return rawCount > 0 ? .absent : .unknown
    }
    guard let raw = match.device, let device = DiskImageCancelBudget.wholeDiskDevice(raw) else {
        return .unknown
    }
    return .device(device)
}

enum RetainedImage {
    case retained(String)
    /// The cancel clock stopped the move. The image is where it was.
    case stopped
    /// No unused retained name could be taken. The image is where it was.
    case left
    /// The path is not the recorded image: a different inode, a symlink, a
    /// non-regular file, or a hard-linked one. Nothing was moved.
    case notOurs
}

/// Moves the detached image of a rejected workspace to a name nothing
/// sweeps: `rv-rejected-<token>-<UTC>.sparseimage` beside it. The
/// `rv-inode-` prefix is what `rv workspace leftovers` lists for deletion,
/// and recovery unlinks only the recorded path, so the new name is neither.
/// `RENAME_EXCL` never replaces a file. The image sits in a directory the
/// cage can write, so the path is untrusted: it is `lstat`ed and must be the
/// recorded regular file with one link before the move (`.notOurs`
/// otherwise), and the mode is narrowed to 0600 through a descriptor opened
/// `O_NOFOLLOW` that is checked against the same inode, never by path. A
/// failed narrowing does not undo the move, because the data is already safe.
func retainRejectedImage(
    _ source: String,
    device: UInt64?,
    inode: UInt64?,
    now: Date = Date()
) -> RetainedImage {
    guard let device, let inode else { return .notOurs }
    let url = URL(fileURLWithPath: source)
    var stem = url.deletingPathExtension().lastPathComponent
    if stem.hasPrefix("rv-inode-") {
        stem = "rv-rejected-" + stem.dropFirst("rv-inode-".count)
    } else {
        stem += "-rejected"
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let stamp = formatter.string(from: now)
    let directory = url.deletingLastPathComponent()
    for attempt in 0..<10 {
        let suffix = attempt == 0 ? "" : "-\(attempt)"
        let destination = directory
            .appendingPathComponent("\(stem)-\(stamp)\(suffix).sparseimage").path
        let verdict = RetainVerdictBox()
        let finished = diskImagePerformWithinCancelClock {
            verdict.value = moveRecordedImage(
                from: source, to: destination, device: device, inode: inode
            )
            return true
        }
        guard finished != nil else { return .stopped }
        switch verdict.value {
        case .moved: return .retained(destination)
        case .notOurs: return .notOurs
        case .nameTaken: continue
        }
    }
    return .left
}

private enum RetainMove {
    case moved
    case notOurs
    case nameTaken
}

private final class RetainVerdictBox: @unchecked Sendable {
    var value = RetainMove.nameTaken
}

/// Runs on the cancel-clock worker. `lstat` pins the recorded identity, the
/// exclusive rename moves that name, and `fchmod` runs on a descriptor that
/// `fstat` proves is the same inode, so a link planted after the check is
/// never chmodded.
private func moveRecordedImage(
    from source: String,
    to destination: String,
    device: UInt64,
    inode: UInt64
) -> RetainMove {
    var before = stat()
    guard source.withCString({ lstat($0, &before) }) == 0,
        (before.st_mode & S_IFMT) == S_IFREG,
        before.st_nlink == 1,
        UInt64(before.st_dev) == device,
        UInt64(before.st_ino) == inode
    else {
        return .notOurs
    }
    let renamed = source.withCString { from in
        destination.withCString { to in
            renamex_np(from, to, UInt32(RENAME_EXCL)) == 0
        }
    }
    guard renamed else { return .nameTaken }
    let fd = destination.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard fd >= 0 else { return .moved }
    defer { close(fd) }
    var after = stat()
    if fstat(fd, &after) == 0,
        (after.st_mode & S_IFMT) == S_IFREG,
        UInt64(after.st_dev) == device,
        UInt64(after.st_ino) == inode
    {
        _ = fchmod(fd, 0o600)
    }
    return .moved
}

#endif
