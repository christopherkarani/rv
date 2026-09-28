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
        let volumeFD = volumeRoot.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard volumeFD >= 0 else { return nil }
        defer { close(volumeFD) }
        let savedFD = savedRoot.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard savedFD >= 0 else { return nil }
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
        var status = stat()
        guard fstat(fd, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFDIR
        else {
            return false
        }
        return device(of: status) == expected
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
        guard let volume = linkTarget(rootFD: volumeFD, relative: relative) else {
            return .discarded
        }
        guard let saved = linkTarget(rootFD: savedFD, relative: relative) else {
            return .abort
        }
        return volume == saved ? .same : .discarded
    }

    private static func linkTarget(rootFD: Int32, relative: String) -> String? {
        guard let parent = openParent(rootFD: rootFD, relative: relative) else { return nil }
        defer { if parent != rootFD { close(parent) } }
        guard let leaf = relative.split(separator: "/").map(String.init).last else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return leaf.withCString { readlinkat(parent, $0, base, pointer.count - 1) }
        }
        guard count >= 0, count < buffer.count - 1 else { return nil }
        buffer[count] = 0
        return String(cString: buffer)
    }

    private static func filesMatch(
        _ relative: String,
        volumeFD: Int32,
        savedFD: Int32,
        budget: inout UInt64
    ) -> Verdict {
        guard let left = openLeaf(rootFD: volumeFD, relative: relative) else {
            return .discarded
        }
        defer { close(left) }
        guard let right = openLeaf(rootFD: savedFD, relative: relative) else {
            return .abort
        }
        defer { close(right) }
        guard isRegular(left) else { return .discarded }
        guard isRegular(right) else { return .abort }
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

    /// Open the parent directory of `relative`, or the root itself when the
    /// name is top-level. The caller closes the result unless it is the root.
    private static func openParent(rootFD: Int32, relative: String) -> Int32? {
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.isEmpty == false, parts.allSatisfy({ $0 != "." && $0 != ".." }) else {
            return nil
        }
        var parent = rootFD
        for part in parts.dropLast() {
            let next = part.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            if parent != rootFD { close(parent) }
            guard next >= 0 else { return nil }
            parent = next
        }
        return parent
    }

    private static func openLeaf(rootFD: Int32, relative: String) -> Int32? {
        guard let parent = openParent(rootFD: rootFD, relative: relative) else { return nil }
        defer { if parent != rootFD { close(parent) } }
        guard let leaf = relative.split(separator: "/").map(String.init).last else { return nil }
        let fd = leaf.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { return nil }
        return fd
    }

    private static func isRegular(_ fd: Int32) -> Bool {
        var status = stat()
        guard fstat(fd, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFREG
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
            var status = stat()
            let stated = name.withCString { item in
                fstatat(fd, item, &status, AT_SYMLINK_NOFOLLOW) == 0
            }
            if stated == false {
                if tolerant, errno == ENOENT {
                    collected.vanished.insert(relative)
                    continue
                }
                if tolerant, errno == EACCES || errno == EPERM {
                    collected.unreadable.insert(relative)
                    continue
                }
                return false
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
                let child = name.withCString { item in
                    openat(fd, item, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else {
                    if tolerant, errno == ENOENT {
                        collected.entries.removeValue(forKey: relative)
                        collected.vanished.insert(relative)
                        continue
                    }
                    if tolerant, errno == EACCES || errno == EPERM {
                        collected.entries.removeValue(forKey: relative)
                        collected.unreadable.insert(relative)
                        continue
                    }
                    return false
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
