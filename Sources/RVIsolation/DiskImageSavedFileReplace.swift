#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// How a clocked file copy ended. `.stopped` means the copy clock
/// returned first: a worker may still be inside a read or write on a
/// duplicate of the destination fd, so the destination inode can still
/// change after this returns. `.failed` is a finished syscall failure.
enum DiskImageCopyOutcome: Equatable, Sendable {
    case finished
    case failed
    case stopped
}

/// File bytes in `chunkBytes` slices. The xattr copy runs only after the
/// bytes finish and the same clock still allows it, so it cannot spend the
/// detach reserve. A stop does not call `copyXattr`.
func copyFileLeavingDetachReserveOutcome(
    from source: Int32,
    to destination: Int32,
    chunkBytes: Int = 64 * 1024,
    mayContinue: (CopyClockPoint) -> Bool,
    copyXattr: (_ source: Int32, _ destination: Int32) -> Bool
) -> DiskImageCopyOutcome {
    let size = chunkBytes > 0 ? chunkBytes : 64 * 1024
    while true {
        if mayContinue(.bytes) == false { return .stopped }
        guard let read = diskImageReadWithinCopyClock(source, maxCount: size) else {
            return .stopped
        }
        if read.errnoValue == EINTR {
            if diskImageInterruptedReadMayRetry(
                errnoValue: read.errnoValue,
                clockAllowsAnotherCall: mayContinue(.bytes)
            ) {
                continue
            }
            return .failed
        }
        if read.count == 0 { break }
        if read.count < 0 { return .failed }
        if mayContinue(.bytes) == false { return .stopped }
        var written = 0
        while written < read.count {
            guard let wrote = diskImageWriteWithinCopyClock(
                destination,
                bytes: read.bytes,
                offset: written,
                count: read.count - written
            ) else {
                return .stopped
            }
            if wrote.errnoValue == EINTR {
                if diskImageInterruptedReadMayRetry(
                    errnoValue: wrote.errnoValue,
                    clockAllowsAnotherCall: mayContinue(.bytes)
                ) {
                    continue
                }
                return .failed
            }
            if wrote.count <= 0 { return .failed }
            written += wrote.count
        }
    }
    if mayContinue(.xattr) == false { return .stopped }
    if copyXattr(source, destination) == false {
        return mayContinue(.xattr) ? .failed : .stopped
    }
    return .finished
}

func copyFileLeavingDetachReserve(
    from source: Int32,
    to destination: Int32,
    chunkBytes: Int = 64 * 1024,
    mayContinue: (CopyClockPoint) -> Bool,
    copyXattr: (_ source: Int32, _ destination: Int32) -> Bool
) -> Bool {
    copyFileLeavingDetachReserveOutcome(
        from: source,
        to: destination,
        chunkBytes: chunkBytes,
        mayContinue: mayContinue,
        copyXattr: copyXattr
    ) == .finished
}

/// A clock stop is not a successful publish, including when a row was
/// already rejected or a staged copy wrote only part of a file.
enum SavedTreePublish: Equatable, Sendable {
    case success
    case failed
}

func savedTreePublishOutcome(
    clockAllowsCopy: Bool,
    rejected: Bool,
    stagedCopyFinished: Bool
) -> SavedTreePublish {
    if clockAllowsCopy == false || rejected || stagedCopyFinished == false {
        return .failed
    }
    return .success
}

/// The original inode is replaced only after the staged copy finished and
/// the clock still leaves the detach reserve. Otherwise the original stays.
func mayReplaceSavedFile(stagedCopyFinished: Bool, clockAllowsCopy: Bool) -> Bool {
    stagedCopyFinished && clockAllowsCopy
}

/// Result of replacing one saved inode from a staged copy.
///
/// `mayRenameOntoWorkspace` is false when `ftruncate` already ran and the
/// backup could not be written back under the clock. That file must not be
/// renamed onto the workspace. A stop before `ftruncate` starts leaves the
/// original bytes in place, so the saved tree may still be restored; a stop
/// with `ftruncate` possibly in flight does not.
struct SavedReplaceOutcome: Equatable, Sendable {
    var committed: Bool
    var reachedTruncate: Bool
    var originalIntact: Bool
    var mayRenameOntoWorkspace: Bool
    /// With `retainBackup`, the host path of the pre-commit bytes after a
    /// commit. The caller owns and unlinks it.
    var retainedBackup: String? = nil
}

func savedTreeMayRenameOntoWorkspace(originalIntact: Bool, restoreFinished: Bool) -> Bool {
    originalIntact && restoreFinished
}

/// Stage `source` onto a temp file. `ftruncate` of `original` runs only
/// when that stage finished and the clock still allows the commit. A clock
/// stop before that leaves `original` untouched. A stop after `ftruncate`
/// restores from the backup under the same clock. It does not force the
/// clock on. A short restore puts the backup file back at `originalPath`
/// and reports that the tree must not be renamed onto the workspace.
func replaceOriginalOnlyAfterStagedCopy(
    source: Int32,
    original: Int32,
    originalPath: String? = nil,
    stagedDirectory: URL = FileManager.default.temporaryDirectory,
    retainBackup: Bool = false,
    mayContinue: (CopyClockPoint) -> Bool,
    copyXattr: (_ source: Int32, _ destination: Int32) -> Bool
) -> SavedReplaceOutcome {
    func untouched() -> SavedReplaceOutcome {
        SavedReplaceOutcome(
            committed: false,
            reachedTruncate: false,
            originalIntact: true,
            mayRenameOntoWorkspace: true
        )
    }
    if mayContinue(.bytes) == false { return untouched() }
    let stagedURL = stagedDirectory
        .appendingPathComponent("rv-stage-\(UUID().uuidString)")
    // `nil` is the copy clock. Do not unlink a path the worker may still
    // be opening. A finished `-1` did not create the file.
    guard let stagedOpened = diskImageOpenPathWithinCopyClock(
        stagedURL.path,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
        mode_t(0o600)
    ) else {
        return untouched()
    }
    guard stagedOpened >= 0 else { return untouched() }
    let staged = stagedOpened
    defer {
        close(staged)
        _ = diskImageUnlinkWithinCopyClock(stagedURL.path)
    }
    guard copyFileLeavingDetachReserve(
        from: source,
        to: staged,
        mayContinue: mayContinue,
        copyXattr: copyXattr
    ) else { return untouched() }
    guard mayReplaceSavedFile(
        stagedCopyFinished: true,
        clockAllowsCopy: mayContinue(.bytes)
    ) else { return untouched() }
    let backupURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-backup-\(UUID().uuidString)")
    guard let backupOpened = diskImageOpenPathWithinCopyClock(
        backupURL.path,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
        mode_t(0o600)
    ) else {
        return untouched()
    }
    guard backupOpened >= 0 else { return untouched() }
    let backup = backupOpened
    var consumedBackup = false
    defer {
        close(backup)
        if consumedBackup == false {
            _ = diskImageUnlinkWithinCopyClock(backupURL.path)
        }
    }
    guard lseek(original, 0, SEEK_SET) == 0 else { return untouched() }
    guard copyFileLeavingDetachReserve(
        from: original,
        to: backup,
        mayContinue: mayContinue,
        copyXattr: { _, _ in true }
    ) else { return untouched() }
    guard mayReplaceSavedFile(
        stagedCopyFinished: true,
        clockAllowsCopy: mayContinue(.bytes)
    ) else { return untouched() }
    guard lseek(staged, 0, SEEK_SET) == 0, lseek(original, 0, SEEK_SET) == 0 else {
        return untouched()
    }
    switch diskImageFtruncateWithinCopyClock(original, 0) {
    case true:
        break
    case false:
        // A finished failure: the truncate did not run.
        return untouched()
    case nil:
        // The parked worker can still truncate the original after this
        // return. The bytes are not known-intact and the tree must not
        // be renamed onto the workspace.
        return SavedReplaceOutcome(
            committed: false,
            reachedTruncate: true,
            originalIntact: false,
            mayRenameOntoWorkspace: false
        )
    }
    let committed = copyFileLeavingDetachReserve(
        from: staged,
        to: original,
        mayContinue: mayContinue,
        copyXattr: copyXattr
    )
    if committed {
        if retainBackup { consumedBackup = true }
        return SavedReplaceOutcome(
            committed: true,
            reachedTruncate: true,
            originalIntact: true,
            mayRenameOntoWorkspace: true,
            retainedBackup: retainBackup ? backupURL.path : nil
        )
    }
    return restoreBackupAfterTruncate(
        original: original,
        originalPath: originalPath,
        backup: backup,
        backupURL: backupURL,
        mayContinue: mayContinue,
        consumedBackup: &consumedBackup
    )
}

func restoreBackupAfterTruncate(
    original: Int32,
    originalPath: String?,
    backup: Int32,
    backupURL: URL,
    mayContinue: (CopyClockPoint) -> Bool,
    consumedBackup: inout Bool
) -> SavedReplaceOutcome {
    let backupSize = descriptorSize(backup)
    if mayContinue(.bytes) {
        _ = lseek(backup, 0, SEEK_SET)
        _ = lseek(original, 0, SEEK_SET)
        let restored = copyFileLeavingDetachReserve(
            from: backup,
            to: original,
            mayContinue: mayContinue,
            copyXattr: { _, _ in true }
        )
        if restored, let backupSize, descriptorSize(original) == backupSize {
            return SavedReplaceOutcome(
                committed: false,
                reachedTruncate: true,
                originalIntact: true,
                mayRenameOntoWorkspace: true
            )
        }
    }
    if let originalPath {
        switch installBackupFile(
            backupURL,
            over: originalPath,
            backup: backup,
            mayContinue: mayContinue
        ) {
        case .restored:
            consumedBackup = true
            return SavedReplaceOutcome(
                committed: false,
                reachedTruncate: true,
                originalIntact: true,
                mayRenameOntoWorkspace: false
            )
        case .preservedBackup:
            consumedBackup = true
            return SavedReplaceOutcome(
                committed: false,
                reachedTruncate: true,
                originalIntact: false,
                mayRenameOntoWorkspace: false
            )
        case .failed:
            break
        }
    }
    return SavedReplaceOutcome(
        committed: false,
        reachedTruncate: true,
        originalIntact: false,
        mayRenameOntoWorkspace: false
    )
}

enum BackupInstall: Equatable, Sendable {
    case restored
    case preservedBackup
    case failed
}

func descriptorSize(_ fd: Int32) -> off_t? {
    final class Box: @unchecked Sendable {
        var size: off_t = 0
        var found = false
    }
    let box = Box()
    let ok = diskImagePerformWithinCopyClock(duplicating: fd) { copy in
        var status = stat()
        let found = fstat(copy, &status) == 0
        close(copy)
        if found { box.size = status.st_size }
        box.found = found
        return true
    }
    guard ok == true, box.found else { return nil }
    return box.size
}

func installBackupFile(
    _ backupURL: URL,
    over path: String,
    backup: Int32,
    mayContinue: (CopyClockPoint) -> Bool
) -> BackupInstall {
    if diskImageSameDevice(backupURL.path, path) {
        let renamed = installBackupByRename(backupURL, over: path, backup: backup)
        if renamed { return .restored }
        if errno == EXDEV {
            return installBackupAcrossDevices(
                backupURL,
                over: path,
                backup: backup,
                mayContinue: mayContinue
            )
        }
        return .failed
    }
    return installBackupAcrossDevices(
        backupURL,
        over: path,
        backup: backup,
        mayContinue: mayContinue
    )
}

func installBackupByRename(_ backupURL: URL, over path: String, backup: Int32) -> Bool {
    let aside = path + ".rv-truncated"
    // A missing aside is a finished `ENOENT`. Only a clock stop skips the
    // rename: the caller is not in `unlink`, and it must not `rename` a
    // path that unlink may still be using.
    guard diskImageUnlinkWithinCopyClock(aside) != nil else {
        errno = EIO
        return false
    }
    guard diskImageRenameWithinCopyClock(path, aside) == true else { return false }
    let installed = diskImageRenameWithinCopyClock(backupURL.path, path)
    guard installed == true else {
        let renameError = errno
        // The install rename is still in the worker. Do not undo it here.
        if installed == false {
            _ = diskImageRenameWithinCopyClock(aside, path)
        }
        errno = renameError
        return false
    }
    _ = diskImageUnlinkWithinCopyClock(aside)
    guard let restored = diskImageFileSizeWithinCopyClock(path) else { return false }
    guard let backupSize = descriptorSize(backup) else { return false }
    return restored == backupSize
}

/// `rename` from `temporaryDirectory` onto a saved tree on another volume
/// is `EXDEV`. Copy under the same clock onto a sibling on the destination
/// volume, then rename that sibling. A short copy removes the truncated
/// inode and leaves the backup in place.
func installBackupAcrossDevices(
    _ backupURL: URL,
    over path: String,
    backup: Int32,
    mayContinue: (CopyClockPoint) -> Bool
) -> BackupInstall {
    let staging = path + ".rv-restore"
    // `nil` is the copy clock. The worker may still be inside `open`, so
    // this thread does not unlink the staging name or the saved file.
    guard let staged = diskImageOpenPathWithinCopyClock(
        staging,
        O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC,
        mode_t(0o600)
    ) else {
        return .failed
    }
    guard staged >= 0 else {
        return preserveTruncatedSaved(path, backupURL: backupURL)
    }
    defer {
        close(staged)
        _ = diskImageUnlinkWithinCopyClock(staging)
    }
    _ = lseek(backup, 0, SEEK_SET)
    let copied = copyFileLeavingDetachReserve(
        from: backup,
        to: staged,
        mayContinue: mayContinue,
        copyXattr: { _, _ in true }
    )
    let stagedSize = descriptorSize(staged)
    let backupSize = descriptorSize(backup)
    let complete = copied && stagedSize == backupSize && stagedSize != nil
    guard complete else {
        return preserveTruncatedSaved(path, backupURL: backupURL)
    }
    let replaced = diskImageRenameWithinCopyClock(staging, path)
    if replaced == true { return .restored }
    if replaced == nil { return .failed }
    return preserveTruncatedSaved(path, backupURL: backupURL)
}

/// The intact bytes survive only in the backup file. Deleting the saved
/// name would leave that backup unrecorded in the temporary directory.
/// Move the truncated file aside in the saved tree and name the backup
/// in a sibling marker, so both artifacts stay discoverable beside the
/// tree that recovery already inspects. A clock stop on the rename is
/// not this outcome, because the truncated file is not yet aside.
private func preserveTruncatedSaved(_ path: String, backupURL: URL) -> BackupInstall {
    let aside = path + ".rv-truncated"
    _ = diskImageUnlinkWithinCopyClock(aside)
    guard diskImageRenameWithinCopyClock(path, aside) == true else { return .failed }
    let marker = path + ".rv-backup-pointer"
    if let markerFD = diskImageOpenPathWithinCopyClock(
        marker,
        O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
        mode_t(0o600)
    ), markerFD >= 0 {
        let text = Array((backupURL.path + "\n").utf8)
        _ = diskImageWriteWithinCopyClock(markerFD, bytes: text, offset: 0, count: text.count)
        close(markerFD)
    }
    return .preservedBackup
}

func unlinkTruncatedSaved(_ path: String) {
    _ = diskImageUnlinkWithinCopyClock(path)
}
