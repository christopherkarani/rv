#if os(macOS)
import Darwin
import Foundation

/// Pre-destruction inventory of a volume abandonment keeps. Unlike the strict
/// snapshot walk, this tolerates exotic files: a socket or FIFO on the volume
/// is destroyed with it, so the escape hatch must not wedge on names the
/// snapshot walk rejects.
struct WorkspaceVolumeDiff: Equatable, Sendable {
    var discarded: [String]
    var discardedCount: Int
    var retained: [String]
    var retainedCount: Int
    var uncomparedCount: Int
    var truncated: Bool

    static let empty = WorkspaceVolumeDiff(
        discarded: [],
        discardedCount: 0,
        retained: [],
        retainedCount: 0,
        uncomparedCount: 0,
        truncated: false
    )
}

enum WorkspaceVolumeDiffer {
    static let listedLimit = 50
    /// Abandonment is a one-shot recovery, so the inventory may spend seconds
    /// of sequential reads for a complete report. Past this many volume bytes
    /// the remaining same-size files count as uncompared instead of stalling.
    static let compareBudget: UInt64 = 1024 * 1024 * 1024

    private enum EntryKind: Equatable {
        case directory
        case regular
        case symlink
        case other
    }

    private struct Entry: Equatable {
        var kind: EntryKind
        var mode: mode_t
        var bytes: UInt64
    }

    private enum Verdict {
        case same
        case discarded
        case uncompared
        case abort
    }

    /// Compare the volume against the saved tree without following symlinks
    /// or crossing devices. Returns nil when the saved tree cannot be fully
    /// read: the survivor must be quiescent, so an unreadable saved tree
    /// fails closed instead of blessing the operation with a clean report.
    /// Volume-side flakes list as discarded, which stays true: that volume
    /// content does not survive regardless of why it was unreadable.
    static func compare(
        volumeRoot: String,
        volumeDevice: UInt64,
        savedRoot: String,
        savedDevice: UInt64
    ) -> WorkspaceVolumeDiff? {
        guard let volumeFD = diskImageOpenPathWithinCopyClock(
            volumeRoot,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        ), volumeFD >= 0 else { return nil }
        defer { close(volumeFD) }
        guard let savedFD = diskImageOpenPathWithinCopyClock(
            savedRoot,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        ), savedFD >= 0 else { return nil }
        defer { close(savedFD) }
        guard onDevice(volumeFD, volumeDevice), onDevice(savedFD, savedDevice) else { return nil }
        guard let volume = collect(root: volumeFD, expectedDevice: volumeDevice, tolerant: true),
            let saved = collect(root: savedFD, expectedDevice: savedDevice, tolerant: false)
        else {
            return nil
        }
        var discarded: [String] = []
        var discardedCount = 0
        var retained: [String] = []
        var retainedCount = 0
        var uncompared = 0
        var budget = compareBudget
        for relative in Set(volume.entries.keys).union(saved.entries.keys).sorted() {
            if volume.unreadable.contains(relative) {
                record(relative, into: &discarded, count: &discardedCount)
                continue
            }
            let onVolume = volume.vanished.contains(relative) ? nil : volume.entries[relative]
            switch (onVolume, saved.entries[relative]) {
            case (nil, nil):
                continue
            case (.some, nil):
                record(relative, into: &discarded, count: &discardedCount)
            case (nil, .some):
                record(relative, into: &retained, count: &retainedCount)
            case (.some(let left), .some(let right)):
                switch classify(
                    relative,
                    volume: left,
                    saved: right,
                    volumeFD: volumeFD,
                    savedFD: savedFD,
                    budget: &budget
                ) {
                case .same:
                    break
                case .discarded:
                    record(relative, into: &discarded, count: &discardedCount)
                case .uncompared:
                    uncompared += 1
                case .abort:
                    return nil
                }
            }
        }
        return WorkspaceVolumeDiff(
            discarded: discarded,
            discardedCount: discardedCount,
            retained: retained,
            retainedCount: retainedCount,
            uncomparedCount: uncompared,
            truncated: discardedCount > discarded.count || retainedCount > retained.count || uncompared > 0
        )
    }

    private static func record(_ relative: String, into listed: inout [String], count: inout Int) {
        count += 1
        if listed.count < listedLimit {
            listed.append(relative)
        }
    }

    private static func onDevice(_ fd: Int32, _ expected: UInt64) -> Bool {
        final class Box: @unchecked Sendable { var status = stat() }
        let box = Box()
        let stated = diskImagePerformWithinCopyClock {
            let copy = diskImageDuplicateDescriptor(fd)
            guard copy >= 0 else { return false }
            let ok = fstat(copy, &box.status) == 0
            close(copy)
            return ok
        }
        guard stated == true, (box.status.st_mode & S_IFMT) == S_IFDIR else { return false }
        return device(of: box.status) == expected
    }

    private static func classify(
        _ relative: String,
        volume: Entry,
        saved: Entry,
        volumeFD: Int32,
        savedFD: Int32,
        budget: inout UInt64
    ) -> Verdict {
        switch (volume.kind, saved.kind) {
        case (.directory, .directory):
            // Directory modes are not compared: the seed creates volume
            // directories through the process umask without restoring modes,
            // so a mode difference there is seed noise, not a discard.
            return .same
        case (.regular, .regular):
            break
        case (.symlink, .symlink):
            return linksMatch(relative, volumeFD: volumeFD, savedFD: savedFD)
        default:
            return .discarded
        }
        guard volume.mode == saved.mode else { return .discarded }
        guard volume.bytes == saved.bytes else { return .discarded }
        return filesMatch(relative, volumeFD: volumeFD, savedFD: savedFD, budget: &budget)
    }

    private static func linksMatch(_ relative: String, volumeFD: Int32, savedFD: Int32) -> Verdict {
        switch linkTarget(rootFD: volumeFD, relative: relative) {
        case .stopped:
            return .abort
        case .failed:
            return .discarded
        case .target(let volume):
            switch linkTarget(rootFD: savedFD, relative: relative) {
            case .stopped, .failed:
                return .abort
            case .target(let saved):
                return volume == saved ? .same : .discarded
            }
        }
    }

    private enum LinkRead {
        case target(String)
        case failed
        case stopped
    }

    private static func linkTarget(rootFD: Int32, relative: String) -> LinkRead {
        switch openParent(rootFD: rootFD, relative: relative) {
        case .stopped:
            return .stopped
        case .failed(_):
            return .failed
        case .fd(let parent):
            defer { if parent != rootFD { close(parent) } }
            guard let leaf = relative.split(separator: "/").map(String.init).last else {
                return .failed
            }
            final class Box: @unchecked Sendable { var text: String? }
            let box = Box()
            let read = diskImagePerformWithinCopyClock {
                let copy = diskImageDuplicateDescriptor(parent)
                guard copy >= 0 else { return false }
                var buffer = [CChar](repeating: 0, count: 4096)
                let count = leaf.withCString { readlinkat(copy, $0, &buffer, buffer.count - 1) }
                close(copy)
                guard count >= 0, count < buffer.count - 1 else { return false }
                box.text = String(
                    decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
                return true
            }
            if read == nil { return .stopped }
            if let text = box.text { return .target(text) }
            return .failed
        }
    }

    private static func filesMatch(
        _ relative: String,
        volumeFD: Int32,
        savedFD: Int32,
        budget: inout UInt64
    ) -> Verdict {
        let left: Int32
        switch openLeaf(rootFD: volumeFD, relative: relative) {
        case .stopped:
            return .abort
        case .failed(_):
            return .discarded
        case .fd(let fd):
            left = fd
        }
        defer { close(left) }
        let right: Int32
        switch openLeaf(rootFD: savedFD, relative: relative) {
        case .stopped, .failed(_):
            return .abort
        case .fd(let fd):
            right = fd
        }
        defer { close(right) }
        switch isRegular(left) {
        case .stopped:
            return .abort
        case .no:
            return .discarded
        case .yes:
            break
        }
        switch isRegular(right) {
        case .stopped, .no:
            return .abort
        case .yes:
            break
        }
        var leftBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        var rightBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let leftCount = readChunk(left, into: &leftBuffer)
            let rightCount = readChunk(right, into: &rightBuffer)
            guard leftCount >= 0 else { return .discarded }
            guard rightCount >= 0 else { return .abort }
            guard leftCount == rightCount else { return .discarded }
            if leftCount == 0 { return .same }
            if budget == 0 { return .uncompared }
            budget = budget > UInt64(leftCount) ? budget - UInt64(leftCount) : 0
            guard leftBuffer.prefix(leftCount).elementsEqual(rightBuffer.prefix(rightCount)) else {
                return .discarded
            }
        }
    }

    private enum OpenedNode {
        case fd(Int32)
        case failed(Int32)
        case stopped
    }

    private enum RegularFile {
        case yes
        case no
        case stopped
    }

    /// Open the parent directory of `relative`, or the root itself when the
    /// name is top-level. The caller closes the result unless it is the root.
    /// A clock stop is `.stopped`, not a missing directory.
    private static func openParent(rootFD: Int32, relative: String) -> OpenedNode {
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.isEmpty == false, parts.allSatisfy({ $0 != "." && $0 != ".." }) else {
            return .failed(EINVAL)
        }
        var parent = rootFD
        var owned = false
        for part in parts.dropLast() {
            switch openatOnClock(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) {
            case .fd(let next):
                if owned { close(parent) }
                parent = next
                owned = true
            case .failed(let err):
                if owned { close(parent) }
                return .failed(err)
            case .stopped:
                if owned { close(parent) }
                return .stopped
            }
        }
        return .fd(parent)
    }

    private static func openLeaf(rootFD: Int32, relative: String) -> OpenedNode {
        switch openParent(rootFD: rootFD, relative: relative) {
        case .stopped:
            return .stopped
        case .failed(let err):
            return .failed(err)
        case .fd(let parent):
            defer { if parent != rootFD { close(parent) } }
            guard let leaf = relative.split(separator: "/").map(String.init).last else {
                return .failed(EINVAL)
            }
            return openatOnClock(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
    }

    private static func isRegular(_ fd: Int32) -> RegularFile {
        final class Box: @unchecked Sendable { var status = stat() }
        let box = Box()
        let stated = diskImagePerformWithinCopyClock {
            let copy = diskImageDuplicateDescriptor(fd)
            guard copy >= 0 else { return false }
            let ok = fstat(copy, &box.status) == 0
            close(copy)
            return ok
        }
        if stated == nil { return .stopped }
        guard stated == true else { return .no }
        return (box.status.st_mode & S_IFMT) == S_IFREG ? .yes : .no
    }

    private enum ClockedStat {
        case value(stat)
        case failed(Int32)
        case stopped
    }

    private static func fstatatOnClock(_ dirfd: Int32, _ name: String) -> ClockedStat {
        final class Box: @unchecked Sendable {
            var status = stat()
            var err: Int32 = 0
            var ok = false
        }
        let box = Box()
        let finished = diskImagePerformWithinCopyClock {
            let copy = diskImageDuplicateDescriptor(dirfd)
            guard copy >= 0 else {
                box.err = errno
                return false
            }
            let stated = name.withCString {
                fstatat(copy, $0, &box.status, AT_SYMLINK_NOFOLLOW) == 0
            }
            if stated == false { box.err = errno }
            close(copy)
            box.ok = stated
            return true
        }
        if finished == nil { return .stopped }
        if finished == false || box.ok == false {
            return .failed(box.err == 0 ? EIO : box.err)
        }
        return .value(box.status)
    }

    private static func openatOnClock(_ dirfd: Int32, _ name: String, _ flags: Int32) -> OpenedNode {
        final class Box: @unchecked Sendable {
            var fd: Int32 = -1
            var err: Int32 = 0
        }
        let box = Box()
        let finished = diskImagePerformWithinCopyClock {
            let copy = diskImageDuplicateDescriptor(dirfd)
            guard copy >= 0 else {
                box.err = errno
                return false
            }
            let opened = name.withCString { openat(copy, $0, flags) }
            if opened < 0 { box.err = errno }
            close(copy)
            box.fd = opened
            return true
        }
        if finished == nil { return .stopped }
        if box.fd < 0 { return .failed(box.err == 0 ? EIO : box.err) }
        return .fd(box.fd)
    }

    private static func readChunk(_ fd: Int32, into buffer: inout [UInt8]) -> Int {
        buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            while true {
                let count = read(fd, base, raw.count)
                if count < 0, errno == EINTR { continue }
                return count
            }
        }
    }

    private struct Collected {
        var entries: [String: Entry]
        var vanished: Set<String>
        var unreadable: Set<String>
    }

    private static func collect(
        root: Int32,
        expectedDevice: UInt64,
        tolerant: Bool
    ) -> Collected? {
        var collected = Collected(entries: [:], vanished: [], unreadable: [])
        guard walk(
            fd: root,
            prefix: "",
            expectedDevice: expectedDevice,
            tolerant: tolerant,
            into: &collected
        ) else {
            return nil
        }
        return collected
    }

    /// Like the strict tree walk, but exotic files classify as `.other`. On
    /// the tolerant (volume) side, names that vanish mid-walk are reported
    /// and permission-denied names are reported unreadable; anything else,
    /// and any failure on the strict (saved) side, fails the walk. A device
    /// crossing always fails: that is mount smuggling, not churn.
    private static func walk(
        fd: Int32,
        prefix: String,
        expectedDevice: UInt64,
        tolerant: Bool,
        into collected: inout Collected
    ) -> Bool {
        guard let names = directoryNames(fd, isWorkspaceRoot: prefix.isEmpty) else { return false }
        for name in names {
            let relative = prefix.isEmpty ? name : prefix + "/" + name
            let status: stat
            switch fstatatOnClock(fd, name) {
            case .stopped:
                return false
            case .failed(let err):
                if tolerant, err == ENOENT {
                    collected.vanished.insert(relative)
                    continue
                }
                if tolerant, err == EACCES || err == EPERM {
                    collected.unreadable.insert(relative)
                    continue
                }
                return false
            case .value(let stated):
                status = stated
            }
            guard device(of: status) == expectedDevice else { return false }
            let entryKind: EntryKind
            switch kind(of: status.st_mode) {
            case .directory:
                entryKind = .directory
            case .regular:
                entryKind = .regular
            case .symlink:
                entryKind = .symlink
            case nil:
                entryKind = .other
            }
            let bytes = entryKind == .regular ? UInt64(status.st_size) : 0
            collected.entries[relative] = Entry(kind: entryKind, mode: modeBits(status.st_mode), bytes: bytes)
            if entryKind == .directory {
                let child: Int32
                switch openatOnClock(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) {
                case .stopped:
                    return false
                case .failed(let err):
                    if tolerant, err == ENOENT {
                        collected.entries.removeValue(forKey: relative)
                        collected.vanished.insert(relative)
                        continue
                    }
                    if tolerant, err == EACCES || err == EPERM {
                        collected.entries.removeValue(forKey: relative)
                        collected.unreadable.insert(relative)
                        continue
                    }
                    return false
                case .fd(let opened):
                    child = opened
                }
                let ok = walk(
                    fd: child,
                    prefix: relative,
                    expectedDevice: expectedDevice,
                    tolerant: tolerant,
                    into: &collected
                )
                close(child)
                if ok == false { return false }
            }
        }
        return true
    }
}
#endif
