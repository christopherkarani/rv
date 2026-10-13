import Foundation
import RVDomain
import Testing
@testable import RVIsolation

// M4: file-content hashing for custom-launch executable binding. The
// chunked file reader must agree byte-for-byte with the single-shot
// hasher, and every unreadable shape must fail closed (nil), never a
// partial-content digest.

struct FileDigestTests {
    @Test func fileHashMatchesSingleShot() throws {
        let url = try writeTemp(bytes: Array("hello executable".utf8))
        #expect(RVFileDigest.sha256HexOfFile(atPath: url.path) == RVDigest.sha256Hex(Array("hello executable".utf8)))
    }

    @Test func emptyFileHashesAsEmpty() throws {
        let url = try writeTemp(bytes: [])
        #expect(RVFileDigest.sha256HexOfFile(atPath: url.path) == RVDigest.sha256Hex([]))
    }

    @Test func multiChunkFileMatchesSingleShot() throws {
        var bytes: [UInt8] = []
        for index in 0..<(200 * 1024) {
            bytes.append(UInt8(index & 0xFF))
        }
        let url = try writeTemp(bytes: bytes)
        #expect(RVFileDigest.sha256HexOfFile(atPath: url.path) == RVDigest.sha256Hex(bytes))
    }

    @Test func missingFileIsNil() {
        #expect(
            RVFileDigest.sha256HexOfFile(atPath: "/nonexistent-rv-dir-\(UUID().uuidString)/nope") == nil
        )
    }

    @Test func directoryIsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-digest-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(RVFileDigest.sha256HexOfFile(atPath: dir.path) == nil)
    }

    @Test func maxBytesAllowsExactSize() throws {
        let bytes = Array("capped executable".utf8)
        let url = try writeTemp(bytes: bytes)
        #expect(
            RVFileDigest.sha256HexOfFile(atPath: url.path, maxBytes: UInt64(bytes.count))
                == RVDigest.sha256Hex(bytes)
        )
    }

    @Test func maxBytesRefusesOverflow() throws {
        let bytes = Array("capped executable".utf8)
        let url = try writeTemp(bytes: bytes)
        #expect(
            RVFileDigest.sha256HexOfFile(atPath: url.path, maxBytes: UInt64(bytes.count) - 1) == nil
        )
    }

    @Test func maxBytesZeroBoundary() throws {
        let empty = try writeTemp(bytes: [])
        #expect(
            RVFileDigest.sha256HexOfFile(atPath: empty.path, maxBytes: 0) == RVDigest.sha256Hex([])
        )
        let one = try writeTemp(bytes: [0x41])
        #expect(RVFileDigest.sha256HexOfFile(atPath: one.path, maxBytes: 0) == nil)
    }

    private func writeTemp(bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-digest-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }
}
