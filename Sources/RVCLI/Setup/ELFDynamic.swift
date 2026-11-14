import Foundation

/// The two facts `rv mcp custodian install` needs from an ELF file: the
/// shared libraries it asks for, and the directories its loader would
/// search for them before the system's. The second is what makes a copy
/// of a binary safe for root to run: a search path that names a directory
/// someone else can write is someone else's code in root's process.
///
/// 64-bit little-endian files only (every platform rv ships for); anything
/// else, a file that does not parse, or one that has its loader bring in
/// code some other way (an audit, filter or auxiliary library) is nil.
struct ELFDynamic: Equatable {
    /// `DT_NEEDED` names, in order.
    var needed: [String]
    /// `DT_RUNPATH` and `DT_RPATH` entries, split at `:`. An empty entry
    /// (the current directory, to a loader) is kept.
    var searchPath: [String]

    private static let loadSegment: UInt32 = 1
    private static let dynamicSegment: UInt32 = 2
    private static let neededTag: UInt64 = 1
    private static let stringTableTag: UInt64 = 5
    private static let sonameTag: UInt64 = 14
    private static let rpathTag: UInt64 = 15
    private static let runpathTag: UInt64 = 29
    /// DT_DEPAUDIT, DT_AUDIT, DT_AUXILIARY, DT_FILTER: libraries named
    /// outside DT_NEEDED.
    private static let otherLibraryTags: Set<UInt64> = [0x6FFF_FEFB, 0x6FFF_FEFC, 0x7FFF_FFFD, 0x7FFF_FFFF]

    private struct Layout {
        /// File offsets of each `DT_NEEDED`, `DT_RPATH` and `DT_RUNPATH` string.
        var needed: [Int] = []
        var paths: [Int] = []
        /// The file's own name (`DT_SONAME`), if it has one.
        var names: [Int] = []
    }

    private static func integer<T: FixedWidthInteger>(_ type: T.Type, _ bytes: [UInt8], at offset: Int) -> T? {
        guard offset >= 0, MemoryLayout<T>.size <= bytes.count, offset <= bytes.count - MemoryLayout<T>.size else {
            return nil
        }
        var value: T = 0
        for index in (0..<MemoryLayout<T>.size).reversed() { value = value << 8 | T(bytes[offset + index]) }
        return value
    }

    private static func string(_ bytes: [UInt8], at offset: Int) -> String? {
        guard offset >= 0, offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }

    private static func layout(_ bytes: [UInt8]) -> Layout? {
        guard bytes.count >= 64, Array(bytes[0..<4]) == [0x7F, 0x45, 0x4C, 0x46], bytes[4] == 2, bytes[5] == 1,
            let headers = integer(UInt64.self, bytes, at: 0x20), let size = integer(UInt16.self, bytes, at: 0x36),
            let count = integer(UInt16.self, bytes, at: 0x38), count <= 512, let table = Int(exactly: headers)
        else { return nil }
        // No program headers: nothing is loaded, so nothing is asked for.
        guard count > 0 else { return Layout() }
        guard size >= 56 else { return nil }
        var loads: [(address: UInt64, offset: UInt64, length: UInt64)] = []
        var dynamic: (offset: Int, length: Int)?
        for index in 0..<Int(count) {
            let (start, overflow) = table.addingReportingOverflow(index * Int(size))
            guard overflow == false, start <= bytes.count, let type = integer(UInt32.self, bytes, at: start),
                let offset = integer(UInt64.self, bytes, at: start + 8),
                let address = integer(UInt64.self, bytes, at: start + 16),
                let length = integer(UInt64.self, bytes, at: start + 32)
            else { return nil }
            if type == loadSegment { loads.append((address, offset, length)) }
            if type == dynamicSegment {
                guard let at = Int(exactly: offset), let extent = Int(exactly: length) else { return nil }
                dynamic = (at, extent)
            }
        }
        // No dynamic section: a static file asks for nothing.
        guard let dynamic else { return Layout() }
        guard dynamic.offset >= 0, dynamic.length >= 0, dynamic.offset <= bytes.count - dynamic.length else { return nil }
        var entries: [(tag: UInt64, value: UInt64)] = []
        for start in stride(from: dynamic.offset, to: dynamic.offset + dynamic.length - 15, by: 16) {
            guard let tag = integer(UInt64.self, bytes, at: start), let value = integer(UInt64.self, bytes, at: start + 8)
            else { return nil }
            if tag == 0 { break }
            entries.append((tag, value))
        }
        guard entries.contains(where: { otherLibraryTags.contains($0.tag) }) == false else { return nil }
        let stringTags = [neededTag, rpathTag, runpathTag, sonameTag]
        guard let address = entries.first(where: { $0.tag == stringTableTag })?.value,
            let segment = loads.first(where: { address >= $0.address && address - $0.address < $0.length }),
            case let (sum, overflow) = segment.offset.addingReportingOverflow(address - segment.address),
            overflow == false, let strings = Int(exactly: sum), strings <= bytes.count
        else { return entries.contains { stringTags.contains($0.tag) } ? nil : Layout() }
        var layout = Layout()
        for entry in entries where stringTags.contains(entry.tag) {
            guard let value = Int(exactly: entry.value), value <= bytes.count - strings else { return nil }
            switch entry.tag {
            case neededTag: layout.needed.append(strings + value)
            case sonameTag: layout.names.append(strings + value)
            default: layout.paths.append(strings + value)
            }
        }
        return layout
    }

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard let layout = Self.layout(bytes) else { return nil }
        var needed: [String] = []
        for offset in layout.needed {
            guard let name = Self.string(bytes, at: offset) else { return nil }
            needed.append(name)
        }
        var search: [String] = []
        for offset in layout.paths {
            guard let path = Self.string(bytes, at: offset) else { return nil }
            if path.isEmpty == false {
                search += path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            }
        }
        self.needed = needed
        searchPath = search
    }

    /// The file with every search path replaced by `$ORIGIN` (its own
    /// directory), or by nothing where `$ORIGIN` does not fit in the space
    /// the old one had. Written in place over the old string, so nothing
    /// else in the file moves. Nil when the file is not one this reads, or
    /// when a library name shares the search path's bytes (a linker may
    /// store one string as the tail of another), which rewriting would
    /// change too.
    static func confined(_ data: Data) -> Data? {
        var bytes = [UInt8](data)
        guard let layout = layout(bytes) else { return nil }
        let origin = Array("$ORIGIN".utf8)
        for offset in layout.paths {
            guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            guard (layout.needed + layout.names).contains(where: { (offset...end).contains($0) }) == false else {
                return nil
            }
            let replacement = end - offset >= origin.count ? origin : []
            for index in offset..<end {
                bytes[index] = index - offset < replacement.count ? replacement[index - offset] : 0
            }
        }
        return Data(bytes)
    }
}
