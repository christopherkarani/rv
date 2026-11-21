#if canImport(CoreML)
import CryptoKit
import Foundation
import Testing
@testable import RVLaya

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// The production digest (`CompiledModelCache.sha256Hex`), not a test
/// stand-in: a digest that returns nil makes every install fail.
@Suite("Compiled model cache digest (real SHA-256)")
struct CompiledModelCacheDigestTests {
    private static func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-digest-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test func emptyFile() throws {
        let url = try Self.file(Data())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CompiledModelCache.sha256Hex(of: url)
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func abc() throws {
        let url = try Self.file(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CompiledModelCache.sha256Hex(of: url)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func multiChunkFileMatchesOneShot() throws {
        let data = Data((0..<(3 << 20) + 12_345).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = try Self.file(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(CompiledModelCache.sha256Hex(of: url) == expected)
    }

    /// End to end with the production digest: one compile, an installed
    /// entry with its manifest, reuse on the next load, nothing left in temp.
    @Test func storeInstallsOnceWithTheRealDigest() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-real-digest-store-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("state/models", isDirectory: true)
        let temp = base.appendingPathComponent("tmp", isDirectory: true)
        let package = base.appendingPathComponent("bundle/model.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let compiles = Counter()
        let guardian = CoreMLGuard(
            store: nil, disk: FakeDisk(free: 100 << 30), cacheVolume: base, purgeCoreMLCache: {}, log: { _ in })
        let store = CompiledModelStore<String>(
            root: root, coreML: guardian, version: "26A428",
            compile: { _ in
                compiles.bump()
                let out = temp.appendingPathComponent("model_\(UUID().uuidString).mlmodelc", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: out.appendingPathComponent("weights"), withIntermediateDirectories: true)
                try Data("model".utf8).write(to: out.appendingPathComponent("model.mil"))
                try Data(repeating: 9, count: (1 << 20) + 17).write(to: out.appendingPathComponent("weights/weight.bin"))
                return out
            },
            load: { try String(contentsOf: $0.appendingPathComponent("model.mil"), encoding: .utf8) },
            digest: CompiledModelCache.sha256Hex)
        #expect(try store.model(package: package) == "model")
        #expect(try store.model(package: package) == "model")
        #expect(compiles.value == 1)
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(entries.filter { $0.hasSuffix(".mlmodelc") }.count == 1)
        #expect(entries.filter { $0.hasSuffix(".manifest.json") }.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
    }

    @Test func symlinkAndFifoAreNotRead() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-digest-odd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target")
        try Data("abc".utf8).write(to: target)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(CompiledModelCache.sha256Hex(of: link) == nil)
        let fifo = dir.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(CompiledModelCache.sha256Hex(of: fifo) == nil)
    }
}
#endif
