#if os(macOS)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

// Spawn-commit executable verification: the size gate must refuse before
// the hash, so the in-lock read stays bounded by the dispatch-captured
// size. A swapped-in huge file refuses after a stat; a fifo refuses
// without opening (opening would block forever with no writer).
struct ExecutableCommitVerificationTests {
    @Test func sizeMatchAndDigestMatchVerifies() throws {
        let bytes = Array("measured executable".utf8)
        let url = try writeTemp(bytes: bytes)
        #expect(
            verifyExecutableContentDigest(
                path: url.path,
                expectedSHA256: RVDigest.sha256Hex(bytes),
                expectedByteCount: UInt64(bytes.count)
            )
        )
    }

    @Test func sizeDriftRefuses() throws {
        let bytes = Array("measured executable".utf8)
        let url = try writeTemp(bytes: bytes)
        #expect(
            verifyExecutableContentDigest(
                path: url.path,
                expectedSHA256: RVDigest.sha256Hex(bytes),
                expectedByteCount: UInt64(bytes.count) + 1
            ) == false
        )
    }

    @Test func hugeSparseSwapRefusesWithoutFullRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-execsparse-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 2 * 1024 * 1024 * 1024)
        try handle.close()
        #expect(
            verifyExecutableContentDigest(
                path: url.path,
                expectedSHA256: RVDigest.sha256Hex(Array("x".utf8)),
                expectedByteCount: 8
            ) == false
        )
    }

    @Test func fifoRefusesWithoutBlocking() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-execfifo-\(UUID().uuidString)")
        #expect(mkfifo(url.path, 0o644) == 0)
        #expect(measureExecutableSize(atPath: url.path) == nil)
        #expect(
            verifyExecutableContentDigest(
                path: url.path,
                expectedSHA256: RVDigest.sha256Hex([]),
                expectedByteCount: 0
            ) == false
        )
    }

    @Test func directoryRefuses() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-execdir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(measureExecutableSize(atPath: url.path) == nil)
        #expect(
            verifyExecutableContentDigest(
                path: url.path,
                expectedSHA256: RVDigest.sha256Hex([]),
                expectedByteCount: 0
            ) == false
        )
    }

    @Test func missingFileRefuses() {
        let missing = "/nonexistent-rv-dir-\(UUID().uuidString)/nope"
        #expect(measureExecutableSize(atPath: missing) == nil)
        #expect(
            verifyExecutableContentDigest(
                path: missing,
                expectedSHA256: RVDigest.sha256Hex([]),
                expectedByteCount: 0
            ) == false
        )
    }

    @Test func unmeasurableExpectationNeverVerifies() throws {
        let bytes = Array("measured executable".utf8)
        let url = try writeTemp(bytes: bytes)
        #expect(
            verifyExecutableContentDigest(
                path: url.path,
                expectedSHA256: RVDigest.sha256Hex(bytes),
                expectedByteCount: nil
            ) == false
        )
    }

    @Test func wrongDigestRefuses() throws {
        let bytes = Array("measured executable".utf8)
        let url = try writeTemp(bytes: bytes)
        #expect(
            verifyExecutableContentDigest(
                path: url.path,
                expectedSHA256: RVDigest.sha256Hex(Array("other".utf8)),
                expectedByteCount: UInt64(bytes.count)
            ) == false
        )
    }

    private func writeTemp(bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-execverify-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }
}
#endif
