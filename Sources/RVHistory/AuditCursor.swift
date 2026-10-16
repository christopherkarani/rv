#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// How far a consumer (`rv audit forward`) has read each ledger, by byte
/// offset. A file that shrank or was replaced restarts at 0: duplicates are
/// possible, loss is not. Linux reuses inodes right away, so a replaced file
/// is also caught by a hash of its first line, which includes `time` — and,
/// when known, by the SHA-256 of the last line already forwarded, so an
/// in-place rewrite that preserves line 1 restarts instead of resuming
/// mid-forged-file.
public struct AuditCursor: Sendable, Equatable, Codable {
    public struct Position: Sendable, Equatable, Codable {
        public var offset: UInt64
        public var inode: UInt64
        public var head: UInt64?
        /// SHA-256 of the last line consumed before `offset`.
        public var lastLineHash: String?

        public init(offset: UInt64, inode: UInt64, head: UInt64? = nil, lastLineHash: String? = nil) {
            self.offset = offset
            self.inode = inode
            self.head = head
            self.lastLineHash = lastLineHash
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
            var lastHash = chunk.start > 0 ? cursor.positions[source.rawValue]?.lastLineHash : nil
            for index in chunk.bytes.indices where chunk.bytes[index] == UInt8(ascii: "\n") {
                if events.count >= limit { break }
                let lineBytes = Array(chunk.bytes[lineStart..<index])
                let line = String(decoding: lineBytes, as: UTF8.self)
                if let event = Self.event(fromLine: Substring(line), source: source) { events.append(event) }
                lastHash = RVDigest.sha256Hex(lineBytes)
                consumed = chunk.start + UInt64(index - chunk.bytes.startIndex + 1)
                lineStart = index + 1
            }
            if consumed == chunk.start, chunk.bytes.count == Self.cursorChunkBytes {
                consumed += UInt64(chunk.bytes.count)
                lastHash = nil // skipped a whole chunk; cannot name the line
            }
            next.positions[source.rawValue] = .init(
                offset: consumed, inode: chunk.inode, head: Self.fingerprint(chunk.head, upTo: consumed),
                lastLineHash: lastHash
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
                offset: file.size, inode: file.inode, head: Self.fingerprint(file.head, upTo: file.size),
                lastLineHash: Self.lineHashEndingAt(file.fd, offset: file.size)
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

    /// Cap for the first-line fingerprint. The hashed span is that line,
    /// through its newline, so per-event fields such as `time` are included.
    /// This only bounds a line that never ends.
    static let headBytes = cursorChunkBytes

    static func chunk(_ url: URL, after position: AuditCursor.Position?) -> Chunk? {
        guard let file = openLedger(url) else { return nil }
        defer { close(file.fd) }
        var start = position?.offset ?? 0
        if position?.inode != file.inode || start > file.size { start = 0 }
        if start > 0, let head = position?.head, head != fingerprint(file.head, upTo: start) { start = 0 }
        if start > 0, let expected = position?.lastLineHash,
            lineHashEndingAt(file.fd, offset: start) != expected
        {
            start = 0
        }
        let bytes = readBytes(file.fd, at: start, count: Int(min(UInt64(cursorChunkBytes), file.size - start)))
        return Chunk(start: start, inode: file.inode, head: file.head, bytes: bytes)
    }

    /// SHA-256 of the line that ends at `offset` (which sits just past a
    /// newline, or at EOF), scanning back at most one chunk. Nil when the
    /// line cannot be bounded — which fails the comparison and restarts.
    static func lineHashEndingAt(_ fd: Int32, offset: UInt64) -> String? {
        guard offset > 0 else { return nil }
        let window = min(offset, UInt64(cursorChunkBytes))
        let bytes = readBytes(fd, at: offset - window, count: Int(window))
        guard bytes.count == Int(window) else { return nil }
        var end = bytes.count
        if bytes.last == UInt8(ascii: "\n") { end -= 1 }
        var start = 0
        if let newline = bytes[..<end].lastIndex(of: UInt8(ascii: "\n")) {
            start = newline + 1
        } else if window < offset {
            return nil
        }
        return RVDigest.sha256Hex(Array(bytes[start..<end]))
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
        let head = readHead(fd, size: size)
        return OpenFile(fd: fd, size: size, inode: UInt64(info.st_ino), head: head)
    }

    /// First ledger line, including its newline. A replaced file that keeps
    /// the shared JSON prefix but changes `time` still hashes differently.
    private static func readHead(_ fd: Int32, size: UInt64) -> [UInt8] {
        let limit = Int(min(UInt64(headBytes), size))
        guard limit > 0 else { return [] }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(limit, 512))
        while bytes.count < limit {
            let slice = readBytes(fd, at: UInt64(bytes.count), count: min(4096, limit - bytes.count))
            if slice.isEmpty { break }
            if let newline = slice.firstIndex(of: UInt8(ascii: "\n")) {
                bytes.append(contentsOf: slice[...newline])
                return bytes
            }
            bytes.append(contentsOf: slice)
        }
        return bytes
    }

    /// FNV-1a over the first line, limited to bytes already consumed. Nil at offset 0.
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
