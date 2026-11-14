#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Whether root can use a path without using what another account chose.
/// `rv mcp custodian install` asks this of every file root runs or copies
/// and of every directory their loaders search.
enum RootTrust {
    /// What `lstat` says about one path, and where it points if it is a link.
    struct Entry: Equatable {
        var owner: UInt32
        var mode: UInt32
        var link: String?
    }

    enum Kind {
        /// A file root runs or copies: it must be there.
        case file
        /// A directory a loader looks names up in: it may be missing, and
        /// then nobody else may be able to make it.
        case searched
    }

    private static let typeMask: UInt32 = 0o170000
    private static let directoryType: UInt32 = 0o040000
    private static let sticky: UInt32 = 0o1000
    private static let maximumLinks = 40

    /// The parts of `path` an account other than root can change, or put
    /// something in its place: `path` itself, each directory on the way to
    /// it, and the same for every link followed. Empty when there is none.
    ///
    /// A directory counts when root does not own it or group or others can
    /// write it. A sticky directory (`/tmp`) is excepted for an entry that
    /// exists, which only its owner can replace there; it is not excepted
    /// where the entry is missing, is the file itself, or the directory is
    /// one a loader searches, because anyone can add a name to it.
    static func changeable(_ path: String, as kind: Kind, inspect: (String) -> Entry?) -> [String] {
        guard path.hasPrefix("/") else { return [path] }
        var pending = path.split(separator: "/").map(String.init)
        var current = ""
        var links = 0
        var found: [String] = []
        func note(_ part: String) {
            let name = part.isEmpty ? "/" : part
            if found.contains(name) == false { found.append(name) }
        }
        func isOpen(_ directory: Entry, strict: Bool) -> Bool {
            directory.owner != 0 || (directory.mode & 0o022 != 0 && (strict || directory.mode & sticky == 0))
        }
        while true {
            guard let directory = inspect(current.isEmpty ? "/" : current), directory.mode & typeMask == directoryType
            else {
                note(current)
                return found
            }
            guard let next = pending.first else {
                // The path named a directory.
                if kind == .file || isOpen(directory, strict: true) { note(current) }
                return found
            }
            if next == "." {
                pending.removeFirst()
                continue
            }
            if next == ".." {
                pending.removeFirst()
                current = (current as NSString).deletingLastPathComponent
                if current == "/" { current = "" }
                continue
            }
            let child = current + "/" + next
            let entry = inspect(child)
            let isLast = pending.count == 1
            if isOpen(directory, strict: entry == nil || (isLast && kind == .file)) { note(current) }
            guard let entry else {
                if kind == .file { note(child) }
                return found
            }
            pending.removeFirst()
            if let link = entry.link {
                links += 1
                guard links <= maximumLinks, entry.owner == 0 else {
                    note(child)
                    return found
                }
                pending = link.split(separator: "/").map(String.init) + pending
                if link.hasPrefix("/") { current = "" }
                continue
            }
            if entry.mode & typeMask == directoryType {
                current = child
                continue
            }
            // Not a directory: the file itself, or a file where a directory should be.
            if isLast == false || kind == .searched || entry.owner != 0 || entry.mode & 0o022 != 0 { note(child) }
            return found
        }
    }

    static func live(_ path: String) -> Entry? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        var link: String?
        if info.st_mode & S_IFMT == S_IFLNK {
            var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return readlink(path, base, bytes.count)
            }
            guard count > 0, count < buffer.count else { return nil }
            link = String(decoding: buffer.prefix(count), as: UTF8.self)
        }
        return Entry(owner: info.st_uid, mode: UInt32(info.st_mode), link: link)
    }
}

/// What one program brings into the process that runs it: the libraries
/// found on its own search path, and every directory searched for them.
struct LoadedCode: Equatable {
    /// Found before the system's directories, in the order a loader meets them.
    var libraries: [String] = []
    /// Every directory the program and those libraries have their loader search.
    var searched: [String] = []

    /// Nil when the program or a library found for it is not an ELF file
    /// this reads, or asks its loader for something this cannot follow:
    /// a library by path, or a search entry that is relative, empty, or
    /// uses a token other than `$ORIGIN`.
    init?(program: String, read: (String) -> Data?, isFile: (String) -> Bool) {
        guard let main = read(program).flatMap(ELFDynamic.init),
            let mainSearch = Self.directories(main, at: program)
        else { return nil }
        searched = mainSearch
        var seen: Set<String> = []
        var queue = [(file: main, search: mainSearch)]
        while queue.isEmpty == false {
            let (file, search) = queue.removeFirst()
            for name in file.needed {
                guard name.contains("/") == false else { return nil }
                guard seen.insert(name).inserted else { continue }
                // Its own search path; an old-style one of the program's is inherited.
                guard let path = (search + mainSearch).lazy.map({ $0 + "/" + name }).first(where: isFile) else {
                    continue
                }
                guard let library = read(path).flatMap(ELFDynamic.init),
                    let librarySearch = Self.directories(library, at: path)
                else { return nil }
                libraries.append(path)
                for directory in librarySearch where searched.contains(directory) == false {
                    searched.append(directory)
                }
                queue.append((library, librarySearch))
            }
        }
    }

    private static func directories(_ file: ELFDynamic, at path: String) -> [String]? {
        let origin = (path as NSString).deletingLastPathComponent
        var directories: [String] = []
        for entry in file.searchPath {
            let expanded = entry.replacingOccurrences(of: "${ORIGIN}", with: origin)
                .replacingOccurrences(of: "$ORIGIN", with: origin)
            guard expanded.hasPrefix("/"), expanded.contains("$") == false else { return nil }
            directories.append(expanded)
        }
        return directories
    }
}
