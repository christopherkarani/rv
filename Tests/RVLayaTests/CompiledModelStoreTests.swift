import Foundation
import Synchronization
import Testing
@testable import RVLaya

/// A fake Core ML: "compiling" writes a small directory into a temp area,
/// "loading" reads it back. Failures are scripted per call.
private final class FakeCoreML: @unchecked Sendable {
    let temp: URL
    let state = Mutex<(compiles: Int, loads: Int, failLoads: Int)>((0, 0, 0))

    init(temp: URL) { self.temp = temp }

    var compiles: Int { state.withLock { $0.compiles } }
    var loads: Int { state.withLock { $0.loads } }
    func failNextLoads(_ count: Int) { state.withLock { $0.failLoads = count } }

    func compile(_ package: URL) throws -> URL {
        state.withLock { $0.compiles += 1 }
        let out = temp.appendingPathComponent("compiled-\(UUID().uuidString).mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: out.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try Data("model".utf8).write(to: out.appendingPathComponent("model.mil"))
        try Data(repeating: 7, count: 4096).write(to: out.appendingPathComponent("weights/weight.bin"))
        return out
    }

    struct LoadFailed: Error {}

    func load(_ dir: URL) throws -> String {
        let fail = state.withLock { s -> Bool in
            s.loads += 1
            guard s.failLoads > 0 else { return false }
            s.failLoads -= 1
            return true
        }
        if fail { throw LoadFailed() }
        return try String(contentsOf: dir.appendingPathComponent("model.mil"), encoding: .utf8)
    }
}

/// Deterministic content digest (FNV-1a over the bytes); stands in for
/// SHA-256 so the tests run without CryptoKit.
private func contentDigest(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in data {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return String(hash, radix: 16)
}

private struct Fixture {
    let base: URL
    let root: URL
    let package: URL
    let coreML: FakeCoreML
    let recorder = Recorder()

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-model-store-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        root = base.appendingPathComponent("caches/rv-laya", isDirectory: true)
        package = base.appendingPathComponent("bundle/model.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let temp = base.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        coreML = FakeCoreML(temp: temp)
    }

    func store(
        free: Int64? = 100 << 30, version: String = "26A428", noRoot: Bool = false,
        compile: ((URL) throws -> URL)? = nil, digest: @escaping (URL) -> String? = contentDigest
    ) -> CompiledModelStore<String> {
        let recorder = self.recorder
        let guardian = CoreMLGuard(
            store: nil, disk: FakeDisk(free: free), cacheVolume: base,
            purgeCoreMLCache: { recorder.purge() }, log: { recorder.log($0) })
        let coreML = self.coreML
        return CompiledModelStore(
            root: noRoot ? nil : root, coreML: guardian, version: version,
            compile: compile ?? { try coreML.compile($0) }, load: { try coreML.load($0) },
            digest: digest)
    }

    func rootEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    func tempEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: coreML.temp.path)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

@Suite("Compiled model store")
struct CompiledModelStoreTests {
    @Test("compiles once, installs atomically, and reuses the entry")
    func compilesOnceThenReuses() throws {
        let f = try Fixture()
        defer { f.remove() }
        #expect(try f.store().model(package: f.package) == "model")
        #expect(try f.store().model(package: f.package) == "model")
        #expect(f.coreML.compiles == 1)
        let entries = try f.rootEntries()
        #expect(entries.filter { $0.hasSuffix(".mlmodelc") }.count == 1)
        #expect(entries.filter { $0.hasSuffix(".manifest.json") }.count == 1)
        #expect(!entries.contains { $0.contains(".partial-") })
        // Core ML's temp compile output is not leaked.
        #expect(try f.tempEntries().isEmpty)
    }

    @Test("a truncated entry fails its manifest and is recompiled")
    func truncatedEntryRecompiles() throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.store().model(package: f.package)
        let dir = try #require(try f.rootEntries().first { $0.hasSuffix(".mlmodelc") })
        try Data(repeating: 7, count: 10).write(to: f.root.appendingPathComponent("\(dir)/weights/weight.bin"))
        #expect(try f.store().model(package: f.package) == "model")
        #expect(f.coreML.compiles == 2)
    }

    @Test("a same-size edit (a planted model) fails its digest and is never loaded")
    func tamperedEntryNeverLoads() throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.store().model(package: f.package)
        let dir = try #require(try f.rootEntries().first { $0.hasSuffix(".mlmodelc") })
        try Data("evil!".utf8).write(to: f.root.appendingPathComponent("\(dir)/model.mil"))
        #expect(try f.store().model(package: f.package) == "model")
        #expect(f.coreML.compiles == 2)
        #expect(f.recorder.all.contains { $0.contains("failed verification") })
    }

    @Test("an oversized or non-regular manifest is not read")
    func oddManifestNotRead() throws {
        let f = try Fixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let big = f.root.appendingPathComponent("big.manifest.json")
        try Data(repeating: 32, count: CompiledModelStore<String>.maximumManifestBytes + 1).write(to: big)
        #expect(CompiledModelStore<String>.readManifest(big) == nil)
        let fifo = f.root.appendingPathComponent("fifo.manifest.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(CompiledModelStore<String>.readManifest(fifo) == nil)
    }

    @Test("an entry without its manifest (crash mid-install) is recompiled")
    func missingManifestRecompiles() throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.store().model(package: f.package)
        let manifest = try #require(try f.rootEntries().first { $0.hasSuffix(".manifest.json") })
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(manifest))
        _ = try f.store().model(package: f.package)
        #expect(f.coreML.compiles == 2)
    }

    @Test("a failed load purges both caches and retries exactly once")
    func failedLoadRetriesOnce() throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.store().model(package: f.package)
        f.coreML.failNextLoads(1)
        #expect(try f.store().model(package: f.package) == "model")
        #expect(f.recorder.purgeCount == 1)
        #expect(f.coreML.compiles == 2)
        #expect(f.recorder.all.contains { $0.contains("retrying once") })
    }

    @Test("a load that keeps failing refuses (review) after the one retry")
    func persistentFailureRefuses() throws {
        let f = try Fixture()
        defer { f.remove() }
        f.coreML.failNextLoads(10)
        #expect(throws: CoreMLLoadRefusal.self) { try f.store().model(package: f.package) }
        #expect(f.coreML.loads == 2)
        #expect(f.recorder.purgeCount == 1)
    }

    @Test("a verified entry whose load keeps failing refuses after the one retry")
    func verifiedEntryLoadFailureRefuses() throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.store().model(package: f.package)
        f.coreML.failNextLoads(10)
        #expect(throws: CoreMLLoadRefusal.self) { try f.store().model(package: f.package) }
        #expect(f.coreML.compiles == 2)
        #expect(f.recorder.purgeCount == 1)
    }

    @Test("a compile that keeps failing refuses after the one retry")
    func persistentCompileFailureRefuses() throws {
        let f = try Fixture()
        defer { f.remove() }
        struct CompileFailed: Error {}
        let compiles = Mutex(0)
        let store = f.store(compile: { _ in
            compiles.withLock { $0 += 1 }
            throw CompileFailed()
        })
        #expect(throws: CoreMLLoadRefusal.self) { try store.model(package: f.package) }
        #expect(compiles.withLock { $0 } == 2)
        #expect(f.coreML.loads == 0)
    }

    @Test("low disk refuses before compiling and is not retried")
    func lowDiskRefusesBeforeCompile() throws {
        let f = try Fixture()
        defer { f.remove() }
        #expect(throws: CoreMLDiskSpaceError.self) {
            try f.store(free: CoreMLGuard.minimumFreeBytes - 1).model(package: f.package)
        }
        #expect(f.coreML.compiles == 0)
        #expect(f.coreML.loads == 0)
        #expect(f.recorder.purgeCount == 0)
    }

    @Test("an OS update gets a new entry and the stale one is swept")
    func osUpdateSweepsStaleEntry() throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.store(version: "26A428").model(package: f.package)
        let before = try f.rootEntries()
        _ = try f.store(version: "26B100").model(package: f.package)
        let after = try f.rootEntries()
        #expect(f.coreML.compiles == 2)
        #expect(after.count == 2)
        #expect(Set(before).isDisjoint(with: after))
    }

    @Test("another bundle's entry and foreign files are kept")
    func sweepKeepsOtherBundles() throws {
        let f = try Fixture()
        defer { f.remove() }
        let other = f.base.appendingPathComponent("other/model.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try f.store().model(package: other)
        let otherEntries = try f.rootEntries()
        let foreign = f.root.appendingPathComponent("guard", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        _ = try f.store().model(package: f.package)
        let after = try f.rootEntries()
        #expect(after.contains("guard"))
        #expect(Set(otherEntries).isSubset(of: after))
        #expect(after.count == otherEntries.count + 3)
    }

    @Test("a symlinked cache root refuses (review); nothing compiles or loads from temp")
    func symlinkedRootRefuses() throws {
        let f = try Fixture()
        defer { f.remove() }
        let elsewhere = f.base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f.root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.root, withDestinationURL: elsewhere)
        #expect(throws: CompiledModelRefusal.self) { try f.store().model(package: f.package) }
        #expect(f.coreML.compiles == 0)
        #expect(f.coreML.loads == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test("no cache root refuses: the compile output is never loaded unverified")
    func noRootRefuses() throws {
        let f = try Fixture()
        defer { f.remove() }
        #expect(throws: CompiledModelRefusal.self) { try f.store(noRoot: true).model(package: f.package) }
        #expect(f.coreML.compiles == 0)
        #expect(f.coreML.loads == 0)
    }

    @Test("a compile output swapped for a symlink refuses; the link is removed, its target untouched")
    func symlinkedCompileOutputRefuses() throws {
        let f = try Fixture()
        defer { f.remove() }
        let planted = f.base.appendingPathComponent("planted.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: planted, withIntermediateDirectories: true)
        try Data("evil!".utf8).write(to: planted.appendingPathComponent("model.mil"))
        let link = f.coreML.temp.appendingPathComponent("model_link.mlmodelc")
        let store = f.store(compile: { _ in
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: planted)
            return link
        })
        #expect(throws: CompiledModelRefusal.self) { try store.model(package: f.package) }
        #expect(f.coreML.loads == 0)
        #expect(try f.tempEntries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: planted.appendingPathComponent("model.mil").path))
        #expect(try f.rootEntries().filter { $0.hasSuffix(".mlmodelc") }.isEmpty)
    }

    @Test("a hard link into the compile output cannot rewrite the installed model")
    func hardLinkedCompileOutputCannotRewrite() throws {
        let f = try Fixture()
        defer { f.remove() }
        let coreML = f.coreML
        let outside = f.base.appendingPathComponent("held-link")
        let store = f.store(compile: { package in
            let out = try coreML.compile(package)
            try FileManager.default.linkItem(at: out.appendingPathComponent("model.mil"), to: outside)
            return out
        })
        #expect(try store.model(package: f.package) == "model")
        try Data("evil!".utf8).write(to: outside)
        #expect(try store.model(package: f.package) == "model")
        #expect(f.coreML.compiles == 1, "the installed copy still verifies")
        #expect(try f.tempEntries().isEmpty)
    }

    @Test("a descriptor held open on the compile output cannot rewrite the installed model")
    func heldDescriptorCannotRewrite() throws {
        let f = try Fixture()
        defer { f.remove() }
        let coreML = f.coreML
        let held = Mutex<Int32>(-1)
        let store = f.store(compile: { package in
            let out = try coreML.compile(package)
            held.withLock { $0 = open(out.appendingPathComponent("model.mil").path, O_RDWR) }
            return out
        })
        #expect(try store.model(package: f.package) == "model")
        let fd = held.withLock { $0 }
        try #require(fd >= 0)
        defer { close(fd) }
        let evil = Array("evil!".utf8)
        #expect(pwrite(fd, evil, evil.count, 0) == evil.count)
        #expect(try store.model(package: f.package) == "model")
        #expect(f.coreML.compiles == 1, "the installed copy still verifies")
    }

    @Test("an unreadable directory in the compile output refuses; nothing is skipped silently", .enabled(if: geteuid() != 0, "root reads mode-000 directories"))
    func unreadableSubdirectoryRefuses() throws {
        let f = try Fixture()
        defer { f.remove() }
        let coreML = f.coreML
        let locked = Mutex<URL?>(nil)
        defer { locked.withLock { $0 }.map { _ = chmod($0.path, 0o700) } }
        let store = f.store(compile: { package in
            let out = try coreML.compile(package)
            let dir = out.appendingPathComponent("weights")
            locked.withLock { $0 = dir }
            chmod(dir.path, 0)
            return out
        })
        #expect(throws: CompiledModelRefusal.self) { try store.model(package: f.package) }
        #expect(f.coreML.loads == 0)
    }

    @Test("the manifest refuses a tree with a directory it cannot read", .enabled(if: geteuid() != 0, "root reads mode-000 directories"))
    func manifestRefusesUnreadableDirectory() throws {
        let f = try Fixture()
        defer { f.remove() }
        let out = try f.coreML.compile(f.package)
        let weights = out.appendingPathComponent("weights")
        #expect(CompiledModelStore<String>.manifest(of: out, digest: contentDigest) != nil)
        chmod(weights.path, 0)
        defer { chmod(weights.path, 0o700) }
        #expect(CompiledModelStore<String>.manifest(of: out, digest: contentDigest) == nil)
    }

    @Test("a compile output that cannot be hashed refuses and leaves nothing behind")
    func unhashableOutputRefuses() throws {
        let f = try Fixture()
        defer { f.remove() }
        #expect(throws: CompiledModelRefusal.self) { try f.store(digest: { _ in nil }).model(package: f.package) }
        #expect(f.coreML.compiles == 1)
        #expect(f.coreML.loads == 0)
        #expect(f.recorder.purgeCount == 0)
        #expect(try f.tempEntries().isEmpty)
        #expect(try f.rootEntries().isEmpty)
    }

    @Test("the refusal reasons say the judge is off and why")
    func refusalReason() {
        let refusal = CompiledModelRefusal(detail: "could not hash the compiled model")
        #expect(refusal.reason.contains("Laya judge"))
        #expect(refusal.reason.contains("could not hash the compiled model"))
        let load = CoreMLLoadRefusal(detail: "LoadFailed()")
        #expect(load.reason.hasPrefix("Laya judge: Core ML could not compile or load the model"))
        #expect(load.reason.contains("LoadFailed()"))
    }
}
