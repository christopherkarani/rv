import Foundation
import Testing
import RVDomain

// M4: file-content hashing for custom-launch executable binding. The
// chunked file reader must agree byte-for-byte with the single-shot
// hasher, and every unreadable shape must fail closed (nil), never a
// partial-content digest.

struct RVDigestFileTests {
    @Test func fileHashMatchesSingleShot() throws {
        let url = try writeTemp(bytes: Array("hello executable".utf8))
        #expect(RVDigest.sha256HexOfFile(atPath: url.path) == RVDigest.sha256Hex(Array("hello executable".utf8)))
    }

    @Test func emptyFileHashesAsEmpty() throws {
        let url = try writeTemp(bytes: [])
        #expect(RVDigest.sha256HexOfFile(atPath: url.path) == RVDigest.sha256Hex([]))
    }

    @Test func multiChunkFileMatchesSingleShot() throws {
        var bytes: [UInt8] = []
        for index in 0..<(200 * 1024) {
            bytes.append(UInt8(index & 0xFF))
        }
        let url = try writeTemp(bytes: bytes)
        #expect(RVDigest.sha256HexOfFile(atPath: url.path) == RVDigest.sha256Hex(bytes))
    }

    @Test func missingFileIsNil() {
        #expect(
            RVDigest.sha256HexOfFile(atPath: "/nonexistent-rv-dir-\(UUID().uuidString)/nope") == nil
        )
    }

    @Test func directoryIsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-digest-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(RVDigest.sha256HexOfFile(atPath: dir.path) == nil)
    }

    private func writeTemp(bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-digest-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }
}
