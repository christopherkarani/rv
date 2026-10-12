#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// How far a consumer (`rv audit forward`) has read each ledger, by byte
/// offset. A file that shrank or was replaced restarts at 0: duplicates are
/// possible, loss is not. Linux reuses inodes right away, so a replaced file
/// is also caught by a hash of its first bytes.
public struct AuditCursor: Sendable, Equatable, Codable {
    public struct Position: Sendable, Equatable, Codable {
        public var offset: UInt64
        public var inode: UInt64
        public var head: UInt64?

        public init(offset: UInt64, inode: UInt64, head: UInt64? = nil) {
            self.offset = offset
            self.inode = inode
            self.head = head
        }
    }

    public var positions: [String: Position]

    public init(positions: [String: Position] = [:]) {
        self.positions = positions
    }
}

extension AuditLedger {
    /// Bytes read per source per call.
    public static let cursorChunkBytes = 4 * 1024 * 1024

    /// Up to `limit` events after `cursor`, oldest first, and the cursor that
    /// follows them. Only complete lines are consumed; a line longer than a
    /// chunk is skipped so it cannot stall the cursor.
    public func events(after cursor: AuditCursor, limit: Int) -> (events: [AuditEvent], next: AuditCursor) {
        var next = cursor
        var events: [AuditEvent] = []
        for source in Source.allCases where events.count < limit {
            let url = configDirectory.appendingPathComponent(source.rawValue, isDirectory: false)
            guard let chunk = Self.chunk(url, after: cursor.positions[source.rawValue]) else { continue }
            var consumed = chunk.start
            var lineStart = chunk.bytes.startIndex
            for index in chunk.bytes.indices where chunk.bytes[index] == UInt8(ascii: "\n") {
                if events.count >= limit { break }
                let line = String(decoding: chunk.bytes[lineStart..<index], as: UTF8.self)
                if let event = Self.event(fromLine: Substring(line), source: source) { events.append(event) }
                consumed = chunk.start + UInt64(index - chunk.bytes.startIndex + 1)
                lineStart = index + 1
            }
            if consumed == chunk.start, chunk.bytes.count == Self.cursorChunkBytes {
                consumed += UInt64(chunk.bytes.count)
            }
            next.positions[source.rawValue] = .init(
                offset: consumed, inode: chunk.inode, head: Self.fingerprint(chunk.head, upTo: consumed)
            )
        }
        return (events.sorted { $0.time < $1.time }, next)
    }

    /// The cursor at the current end of every ledger (forward from now on).
    public func endCursor() -> AuditCursor {
        var cursor = AuditCursor()
        for source in Source.allCases {
            let url = configDirectory.appendingPathComponent(source.rawValue, isDirectory: false)
            guard let file = Self.openLedger(url) else { continue }
            defer { close(file.fd) }
            cursor.positions[source.rawValue] = .init(
                offset: file.size, inode: file.inode, head: Self.fingerprint(file.head, upTo: file.size)
            )
        }
        return cursor
    }

    struct Chunk {
        var start: UInt64
        var inode: UInt64
        var head: [UInt8]
        var bytes: [UInt8]
    }

    /// Bytes hashed to tell a replaced file from the one the cursor saw.
    static let headBytes = 64

    static func chunk(_ url: URL, after position: AuditCursor.Position?) -> Chunk? {
        guard let file = openLedger(url) else { return nil }
        defer { close(file.fd) }
        var start = position?.offset ?? 0
        if position?.inode != file.inode || start > file.size { start = 0 }
        if start > 0, let head = position?.head, head != fingerprint(file.head, upTo: start) { start = 0 }
        let bytes = readBytes(file.fd, at: start, count: Int(min(UInt64(cursorChunkBytes), file.size - start)))
        return Chunk(start: start, inode: file.inode, head: file.head, bytes: bytes)
    }

    private struct OpenFile {
        var fd: Int32
        var size: UInt64
        var inode: UInt64
        var head: [UInt8]
    }

    private static func openLedger(_ url: URL) -> OpenFile? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return nil
        }
        let size = UInt64(info.st_size)
        let head = readBytes(fd, at: 0, count: Int(min(UInt64(headBytes), size)))
        return OpenFile(fd: fd, size: size, inode: UInt64(info.st_ino), head: head)
    }

    /// FNV-1a over the first `min(offset, headBytes)` bytes; nil at offset 0.
    static func fingerprint(_ head: [UInt8], upTo offset: UInt64) -> UInt64? {
        let count = Int(min(offset, UInt64(head.count)))
        guard count > 0 else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in head.prefix(count) {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private static func readBytes(_ fd: Int32, at offset: UInt64, count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let read = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return pread(fd, base + filled, count - filled, off_t(offset) + off_t(filled))
            }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { break }
            filled += read
        }
        bytes.removeSubrange(filled...)
        return bytes
    }
}
