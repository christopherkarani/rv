#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

func directoryReadMayContinue(_ mayContinue: Bool) -> Bool {
    mayContinue
}

#if canImport(Darwin)
private typealias DirectoryStream = UnsafeMutablePointer<DIR>
#else
private typealias DirectoryStream = OpaquePointer
#endif

/// Holds a `DIR` opened off the caller. A clock stop leaks it instead of
/// closing it while `readdir` or `fdopendir` may still be inside the call.
private final class DirectoryHold: @unchecked Sendable {
    private let lock = NSLock()
    private var dir: DirectoryStream?
    private var leaked = false

    func store(_ opened: DirectoryStream?) {
        lock.lock()
        dir = opened
        lock.unlock()
    }

    func take() -> DirectoryStream? {
        lock.lock()
        let opened = dir
        lock.unlock()
        return opened
    }

    func leak() {
        lock.lock()
        leaked = true
        lock.unlock()
    }

    func closeUnlessLeaked() {
        lock.lock()
        let opened = dir
        let shouldClose = leaked == false
        dir = nil
        lock.unlock()
        if shouldClose, let opened {
            closedir(opened)
        }
    }
}

private final class DirectoryPointer: @unchecked Sendable {
    let dir: DirectoryStream
    init(_ dir: DirectoryStream) { self.dir = dir }
}

private final class DirectoryEntryBox: @unchecked Sendable {
    var name: String?
    var ended = false
    var err: Int32 = 0
}

/// `readdir` stops while detach time is still left. A partial listing is
/// not a snapshot: the caller fails the copy instead of publishing it.
/// Each `readdir` runs off the caller and returns at the copy clock even
/// when the call itself does not.
func readDirectoryNamesStoppingForDetachReserve(
    _ path: String,
    mayContinue: () -> Bool
) -> [String]? {
    if directoryReadMayContinue(mayContinue()) == false { return nil }
    let hold = DirectoryHold()
    defer { hold.closeUnlessLeaked() }
    let opened = diskImagePerformWithinCopyClock {
        let dir = path.withCString { opendir($0) }
        hold.store(dir)
        return dir != nil
    }
    if opened == nil {
        hold.leak()
        return nil
    }
    guard opened == true, let dir = hold.take() else { return nil }
    return readDirectoryEntries(DirectoryPointer(dir), mayContinue: mayContinue, hold: hold)
}

/// Same stop, on a directory fd. `fdopendir` consumes a duplicate so the
/// caller's fd stays open. The duplicate is taken on the caller.
func readDirectoryNames(
    _ dirfd: Int32,
    mayContinue: () -> Bool
) -> [String]? {
    if directoryReadMayContinue(mayContinue()) == false { return nil }
    let hold = DirectoryHold()
    defer { hold.closeUnlessLeaked() }
    let opened = diskImagePerformWithinCopyClock(duplicating: dirfd) { copy in
        if lseek(copy, 0, SEEK_SET) < 0 {
            close(copy)
            return false
        }
        let dir = fdopendir(copy)
        if dir == nil {
            close(copy)
            hold.store(nil)
            return false
        }
        hold.store(dir)
        return true
    }
    if opened == nil {
        hold.leak()
        return nil
    }
    guard opened == true, let dir = hold.take() else { return nil }
    return readDirectoryEntries(DirectoryPointer(dir), mayContinue: mayContinue, hold: hold)
}

private func readDirectoryEntries(
    _ dir: DirectoryPointer,
    mayContinue: () -> Bool,
    hold: DirectoryHold
) -> [String]? {
    var names: [String] = []
    while true {
        if directoryReadMayContinue(mayContinue()) == false { return nil }
        let box = DirectoryEntryBox()
        let ok = diskImagePerformWithinCopyClock {
            errno = 0
            if let entry = readdir(dir.dir) {
                box.name = directoryEntryName(entry)
            } else {
                box.ended = true
                box.err = errno
            }
            return true
        }
        if ok == nil {
            hold.leak()
            return nil
        }
        if box.ended {
            if box.err != 0 { return nil }
            break
        }
        if let name = box.name, name != ".", name != ".." {
            names.append(name)
        }
    }
    return names
}

private func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
    withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 1024) {
            String(cString: $0)
        }
    }
}
