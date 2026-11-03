#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization

func establishWorkspaceInodeBoundary(
    at workspacePath: String
) -> Result<WorkspaceInodeBoundary, IsolationApplyError> {
    if blockingWorkIsCancelled() {
        return .failure(.cancelled)
    }
    // A launch cancelled mid-establish can leave the project hidden at a
    // sibling `.rv-saved-*` with no journal record yet. Put it back (or
    // refuse, when the name is occupied) before opening anything.
    switch recoverOrphanedSavedTree(at: workspacePath) {
    case .blocked:
        return .failure(.workspaceInodeBoundaryFailed)
    case .none, .restored:
        break
    }
    guard let rootOpened = diskImageOpenPathWithinCopyClock(
        workspacePath,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    ) else {
        return .failure(.workspaceInodeBoundaryFailed)
    }
    guard rootOpened >= 0 else { return .failure(.workspaceInodeBoundaryFailed) }
    let rootFD = rootOpened
    guard let rootStatus = fstatWithinCopyClock(rootFD) else {
        close(rootFD)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    let originalDevice = device(of: rootStatus)
    guard let captured = collectTree(root: rootFD, checkDevice: originalDevice) else {
        close(rootFD)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    for entry in captured.values where entry.kind == .regular && entry.stamp.linkCount > 1 {
        close(rootFD)
        return .failure(.workspaceContainsInodeAlias)
    }
    close(rootFD)

    let parent = (workspacePath as NSString).deletingLastPathComponent
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    let savedPath = (parent as NSString).appendingPathComponent(".rv-saved-\(token)")
    let quarantinePath = (parent as NSString).appendingPathComponent(".rv-quarantine-\(token)")
    let byteCount = captured.values.reduce(UInt64(0)) { $0 + $1.bytes }
    guard renamePath(workspacePath, savedPath) else {
        return .failure(.workspaceInodeBoundaryFailed)
    }
    switch diskImageMkdirWithinCopyClock(workspacePath, 0o700) {
    case true:
        break
    case nil, false:
        // A parked mkdir landing after the rename-back fails EEXIST;
        // one that landed first is an empty directory the rename
        // replaces. Either way the tree must not stay hidden.
        restoreSavedOrMarkOrphan(savedPath: savedPath, workspacePath: workspacePath)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    let mounted: MountedDisk
    switch createMountedDisk(byteCount: byteCount, mountPoint: workspacePath, token: String(token)) {
    case .failure(let error):
        restoreSavedOrMarkOrphan(savedPath: savedPath, workspacePath: workspacePath)
        return .failure(error)
    case .success(let disk):
        mounted = disk
    }
    func failMounted(
        saved: Int32 = -1,
        volume: Int32 = -1
    ) -> Result<WorkspaceInodeBoundary, IsolationApplyError> {
        if saved >= 0 { close(saved) }
        if volume >= 0 { close(volume) }
        let detached = detachWorkspaceDisk(mounted.disk, mountPoint: workspacePath)
        // No rmdir first: after detach the mount point is the empty
        // directory mkdir made, which rename replaces. A parked rmdir
        // could otherwise land on the restored tree.
        restoreSavedOrMarkOrphan(savedPath: savedPath, workspacePath: workspacePath)
        unlinkImageIfDetached(mounted.imagePath, detachSucceeded: detached)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    if diskImageChmodWithinCopyClock(workspacePath, 0o700) != true {
        return failMounted()
    }
    guard case let .device(volumeDevice) = observedDevice(workspacePath),
        volumeDevice != originalDevice
    else {
        return failMounted()
    }
    // `nil` means a read-only open may still be in flight. Renaming the
    // saved tree back is safe against it (the descriptor, if one lands,
    // is leaked read-only), and leaving the tree hidden is not.
    guard let savedOpened = diskImageOpenPathWithinCopyClock(
        savedPath,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    ) else {
        return failMounted()
    }
    guard savedOpened >= 0 else { return failMounted() }
    let savedFD = savedOpened
    guard let volumeOpened = diskImageOpenPathWithinCopyClock(
        workspacePath,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    ) else {
        return failMounted(saved: savedFD)
    }
    guard savedFD >= 0, volumeOpened >= 0 else {
        return failMounted(saved: savedFD, volume: volumeOpened)
    }
    let volumeFD = volumeOpened
    guard let savedStatus = fstatWithinCopyClock(savedFD),
        device(of: savedStatus) == originalDevice
    else {
        return failMounted(saved: savedFD, volume: volumeFD)
    }
    if copyTree(from: savedFD, to: volumeFD, expectDevice: originalDevice) == false {
        return failMounted(saved: savedFD, volume: volumeFD)
    }
    guard let volumeStatus = fstatWithinCopyClock(volumeFD),
        device(of: volumeStatus) == volumeDevice
    else {
        return failMounted(saved: savedFD, volume: volumeFD)
    }
    guard let mountSource = workspaceMountSource(workspacePath), mountSource.isEmpty == false else {
        return failMounted(saved: savedFD, volume: volumeFD)
    }
    let imageIdentity = mounted.imagePath.flatMap(workspacePathIdentity)
    if mounted.imagePath != nil, imageIdentity?.isDirectory != false {
        return failMounted(saved: savedFD, volume: volumeFD)
    }
    let boundary = WorkspaceInodeBoundary(
        workspacePath: workspacePath,
        savedPath: savedPath,
        quarantinePath: quarantinePath,
        imagePath: mounted.imagePath,
        disk: mounted.disk,
        volumeDevice: volumeDevice,
        savedDevice: originalDevice,
        savedInode: UInt64(savedStatus.st_ino),
        mountSource: mountSource,
        imageDevice: imageIdentity?.device,
        imageInode: imageIdentity?.inode,
        volumeFD: volumeFD,
        savedFD: savedFD,
        snapshot: captured.mapValues(\.stamp)
    )
    guard boundary.relocateHeldDescriptors(atLeast: 16) else {
        _ = boundary.discardAndRestore()
        return .failure(.workspaceInodeBoundaryFailed)
    }
    return .success(boundary)
}

private struct MountedDisk {
    var disk: String
    var imagePath: String?
}

struct TreeEntry {
    var stamp: WorkspaceInodeStamp
    var mode: mode_t
    var bytes: UInt64
    var kind: WorkspaceInodeStamp.Kind { stamp.kind }
}

private func createMountedDisk(
    byteCount: UInt64,
    mountPoint: String,
    token: String
) -> Result<MountedDisk, IsolationApplyError> {
    let first = createMountedDiskBody(byteCount: byteCount, mountPoint: mountPoint, token: token)
    guard case .failure(.workspaceInodeBoundaryFailed) = first.result else { return first.result }
    // A timed-out helper was killed because diskimagesd stopped answering.
    // Retrying it stacks another full deadline onto the shard. A helper
    // that exited nonzero is the transient failure the retry is for.
    if blockingWorkIsCancelled() || diskImageMayRetryCreate(
        publishedDisk: first.publishedDisk,
        detachSucceeded: first.detachSucceeded,
        timedOut: first.timedOut
    ) == false {
        return first.result
    }
    usleep(100_000)
    let image = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-inode-\(token).sparseimage").path
    // Process exit plus a detach that exited 0 is not enough. Unlink only
    // when that attempt already proved the disk cannot appear.
    if diskImageMayRemoveImage(detachSucceeded: first.detachSucceeded) {
        if diskImageUnlinkWithinCopyClock(image) == nil {
            return .failure(.workspaceInodeBoundaryFailed)
        }
    }
    return createMountedDiskBody(byteCount: byteCount, mountPoint: mountPoint, token: token).result
}

private func createMountedDiskBody(
    byteCount: UInt64,
    mountPoint: String,
    token: String
) -> MountedDiskAttempt {
    // Productive builds need headroom the project itself does not predict:
    // `.build`, `node_modules`, and `target` routinely exceed the source
    // tree by orders of magnitude. A sparse image makes the ceiling cheap
    // (blocks allocate on write), so size for real builds, not for the
    // source size. Disk-backed always: a build-sized ram disk would pin
    // gigabytes of RAM per workspace.
    let gib: UInt64 = 1024 * 1024 * 1024
    let overhead = byteCount &* 2 &+ gib
    let minimum: UInt64 = gib
    let bytes = max(overhead, minimum)
    let image = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-inode-\(token).sparseimage").path
    let megabytes = max(Int(bytes / (1024 * 1024)) + 1, 32)
    var timedOut = false
    var publishedDisk = false
    var detachSucceeded = true
    let clock = DiskImageCancelClock()
    func finish(_ result: Result<MountedDisk, IsolationApplyError>) -> MountedDiskAttempt {
        MountedDiskAttempt(
            result: result,
            timedOut: timedOut,
            publishedDisk: publishedDisk,
            detachSucceeded: detachSucceeded
        )
    }
    let created = runTool(
        [
            "/usr/bin/hdiutil", "create", "-size", "\(megabytes)m",
            "-fs", "Case-sensitive HFS+",
            "-volname", "rv\(token.prefix(8))", "-type", "SPARSE", "-quiet", image,
        ],
        honorCancellation: true,
        clock: clock
    )
    timedOut = created.timedOut
    guard created.status == 0 else {
        // A timed-out create may still be in diskimagesd. Unlink only
        // when that helper has already exited.
        if created.timedOut == false {
            if diskImageUnlinkWithinCopyClock(image) == nil {
                timedOut = true
            }
        }
        return finish(.failure(.workspaceInodeBoundaryFailed))
    }
    // `-nomount` plus a direct mount_hfs of the HFS slice: attaching
    // with a mountpoint asks DiskArbitration to mount, which wedges when
    // the daemon is unresponsive. Owners stay honored, matching the old
    // `-owners on` attach.
    let attached = runTool(
        ["/usr/bin/hdiutil", "attach", "-nomount", "-plist", image],
        honorCancellation: true,
        clock: clock
    )
    timedOut = timedOut || attached.timedOut
    guard attached.status == 0 else {
        // A preempted or failed attach can publish a disk before it exits.
        // The in-lock path already detached when the helper was preempted
        // or still alive. A later detach that exits 0 must not unlink
        // while that parked attach can still publish.
        publishedDisk = true
        let leaked = PreemptedDiskHelperCleanup.plan(arguments: [
            "/usr/bin/hdiutil", "attach", "-nomount", "-plist", image,
        ])
        // A parked attach can still publish. Do not detach it. A reaped
        // timeout already detached inside runTool and still may detach here.
        if attached.helperStillAlive {
            detachSucceeded = false
            timedOut = true
            return finish(.failure(.workspaceInodeBoundaryFailed))
        }
        let detachThis = diskImageMustDetachBeforeUnlock(
            cleanup: leaked,
            helperStillAlive: attached.helperStillAlive,
            preempted: false,
            timedOut: attached.timedOut,
            status: attached.status
        )
        // `hdiutil detach` takes the published device, never the image
        // path. Resolve it from the attach plist when one was printed.
        let follow = DiskImageCancelBudget.detachTargetWhenPlistMissesDisk(
            image: image,
            plistStdout: attached.stdout,
            mountPoint: mountPoint
        ).map { DiskImageCancelBudget.detachArguments(device: $0) }
        if let follow, detachThis || attached.timedOut == false {
            let detached = runTool(
                follow,
                honorCancellation: false,
                deadline: DiskImageCancelBudget.preemptCleanup,
                clock: clock
            )
            let detachOutput = detached.stderr + "\n" + detached.stdout
            // Exit 0 is not proof the disk is gone. This call does not
            // wait out diskimagesd, so the image stays until a later
            // cleanup that has.
            let canAppear = diskImageCanStillAppear(
                helperStillAlive: detached.helperStillAlive,
                detachStatus: detached.status,
                detachTimedOut: detached.timedOut,
                detachOutput: detachOutput,
                imageListedAfterDetach: nil,
                waitedForPublication: false
            )
            detachSucceeded = diskImageMayUnlinkPublishedImage(
                helperStillAlive: detached.helperStillAlive,
                detachSucceeded: DiskImageCancelBudget.preemptCleanupSucceeded(
                    status: detached.status,
                    timedOut: detached.timedOut
                ),
                diskCanStillAppear: canAppear
            )
            if diskImageMayRemoveImage(detachSucceeded: detachSucceeded) {
                if diskImageUnlinkWithinCopyClock(image) == nil {
                    detachSucceeded = false
                    timedOut = true
                }
            } else {
                timedOut = true
            }
        } else {
            detachSucceeded = false
            timedOut = true
        }
        return finish(.failure(.workspaceInodeBoundaryFailed))
    }
    guard let disk = diskDevice(inPlist: attached.stdout) else {
        // No resolvable device: detaching by image path cannot work.
        // Fail closed and leave the image for a later cleanup.
        if let target = DiskImageCancelBudget.detachTargetWhenPlistMissesDisk(
            image: image,
            plistStdout: attached.stdout,
            mountPoint: mountPoint
        ) {
            _ = runTool(
                DiskImageCancelBudget.detachArguments(device: target),
                honorCancellation: false,
                deadline: DiskImageCancelBudget.detachCap,
                clock: clock
            )
        }
        publishedDisk = true
        // Even when a detach ran, exit 0 is not permission to unlink or
        // retry while diskimagesd can still publish this image.
        detachSucceeded = false
        timedOut = true
        return finish(.failure(.workspaceInodeBoundaryFailed))
    }
    publishedDisk = true
    guard let slice = hfsSliceDevice(inPlist: attached.stdout) else {
        _ = detachWorkspaceDisk(disk, mountPoint: nil)
        detachSucceeded = false
        timedOut = true
        return finish(.failure(.workspaceInodeBoundaryFailed))
    }
    if blockingWorkIsCancelled() {
        let detached = detachWorkspaceDisk(disk, mountPoint: nil)
        detachSucceeded = false
        timedOut = true
        // Exit 0 is not the disk being gone, and it is not `.cancelled`.
        if establishCancelReportsCancelled(detachExitedZero: detached) {
            return finish(.failure(.cancelled))
        }
        return finish(.failure(.workspaceInodeBoundaryFailed))
    }
    let mounted = runTool(
        ["/sbin/mount_hfs", "-o", "nobrowse,nodev,nosuid", slice, mountPoint],
        honorCancellation: true,
        clock: clock
    )
    timedOut = timedOut || mounted.timedOut
    guard mounted.status == 0 else {
        _ = detachWorkspaceDisk(disk, mountPoint: mountPoint)
        detachSucceeded = false
        timedOut = true
        return finish(.failure(.workspaceInodeBoundaryFailed))
    }
    return finish(.success(MountedDisk(disk: disk, imagePath: image)))
}

private struct MountedDiskAttempt {
    var result: Result<MountedDisk, IsolationApplyError>
    var timedOut: Bool
    var publishedDisk: Bool
    var detachSucceeded: Bool
}

/// `system-entities` from `hdiutil attach -plist` output as typed values.
/// Plist XML carries only JSON-shaped values here (strings, booleans,
/// arrays, dicts); malformed XML or anything outside that shape fails
/// closed to nil.
func systemEntities(inPlist stdout: String) -> [JSONValue]? {
    guard let data = stdout.data(using: .utf8),
        let root = try? PropertyListDecoder().decode(JSONValue.self, from: data)
    else { return nil }
    return root["system-entities"]?.asArray
}

private func diskDevice(inPlist stdout: String) -> String? {
    guard let entities = systemEntities(inPlist: stdout) else { return nil }
    let devices = entities.compactMap { $0["dev-entry"]?.string }
    // Whole disk (`/dev/disk4`), never a slice (`/dev/disk4s1`).
    if let whole = devices.first(where: { DiskImageCancelBudget.wholeDiskDevice($0) == $0 }) {
        return whole
    }
    return devices.lazy.compactMap { DiskImageCancelBudget.wholeDiskDevice($0) }.first
}
#endif
