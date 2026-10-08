import Foundation
import RVDomain
import Testing
@testable import RVIsolation

// M4: shell-side file-content hashing for custom-launch executable
// binding. The chunked file reader must agree byte-for-byte with the
// single-shot hasher, and every unreadable shape must fail closed
// (nil), never a partial-content digest. One test per row of the
// section-9 semantics table, except mid-read I/O failure, which has
// no deterministic trigger: its `catch` returns nil through code
// identical to the former domain reader, preserved by construction.

struct ExecutableDigestTests {
    @Test func fileHashMatchesSingleShot() throws {
        let url = try writeTemp(bytes: Array("hello executable".utf8))
        #expect(fileSHA256Hex(atPath: url.path) == RVDigest.sha256Hex(Array("hello executable".utf8)))
    }

    @Test func emptyFileHashesAsEmpty() throws {
        let url = try writeTemp(bytes: [])
        #expect(fileSHA256Hex(atPath: url.path) == RVDigest.sha256Hex([]))
    }

    @Test func multiChunkFileMatchesSingleShot() throws {
        var bytes: [UInt8] = []
        for index in 0..<(200 * 1024) {
            bytes.append(UInt8(index & 0xFF))
        }
        let url = try writeTemp(bytes: bytes)
        #expect(fileSHA256Hex(atPath: url.path) == RVDigest.sha256Hex(bytes))
    }

    @Test func missingFileIsNil() {
        #expect(
            fileSHA256Hex(atPath: "/nonexistent-rv-dir-\(UUID().uuidString)/nope") == nil
        )
    }

    @Test func directoryIsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-digest-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(fileSHA256Hex(atPath: dir.path) == nil)
    }

    @Test func maxBytesAllowsExactSize() throws {
        let bytes = Array("capped executable".utf8)
        let url = try writeTemp(bytes: bytes)
        #expect(
            fileSHA256Hex(atPath: url.path, maxBytes: UInt64(bytes.count))
                == RVDigest.sha256Hex(bytes)
        )
    }

    @Test func maxBytesRefusesOverflow() throws {
        let bytes = Array("capped executable".utf8)
        let url = try writeTemp(bytes: bytes)
        #expect(
            fileSHA256Hex(atPath: url.path, maxBytes: UInt64(bytes.count) - 1) == nil
        )
    }

    @Test func maxBytesZeroBoundary() throws {
        let empty = try writeTemp(bytes: [])
        #expect(
            fileSHA256Hex(atPath: empty.path, maxBytes: 0) == RVDigest.sha256Hex([])
        )
        let one = try writeTemp(bytes: [0x41])
        #expect(fileSHA256Hex(atPath: one.path, maxBytes: 0) == nil)
    }

    @Test func maxBytesRefusesMidFileOverflow() throws {
        var bytes: [UInt8] = []
        for index in 0..<(200 * 1024) {
            bytes.append(UInt8(index & 0xFF))
        }
        let url = try writeTemp(bytes: bytes)
        #expect(
            fileSHA256Hex(atPath: url.path, maxBytes: UInt64(bytes.count))
                == RVDigest.sha256Hex(bytes)
        )
        #expect(fileSHA256Hex(atPath: url.path, maxBytes: 100 * 1024) == nil)
    }

    @Test func symlinkHashesLiveTarget() throws {
        let first = try writeTemp(bytes: Array("link target one".utf8))
        let second = try writeTemp(bytes: Array("link target two".utf8))
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-digest-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        #expect(fileSHA256Hex(atPath: link.path) == RVDigest.sha256Hex(Array("link target one".utf8)))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        #expect(fileSHA256Hex(atPath: link.path) == RVDigest.sha256Hex(Array("link target two".utf8)))
    }

    @Test func unreadableFileIsNil() throws {
        let url = try writeTemp(bytes: Array("no read permission".utf8))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        guard FileManager.default.isReadableFile(atPath: url.path) == false else {
            Issue.record("unreadable-file refusal is unverifiable when the file stays readable; rerun unprivileged")
            return
        }
        #expect(fileSHA256Hex(atPath: url.path) == nil)
    }

    private func writeTemp(bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-digest-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }
}
