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

    func store(free: Int64? = 100 << 30, version: String = "26A428") -> CompiledModelStore<String> {
        let recorder = self.recorder
        let guardian = CoreMLGuard(
            store: nil, disk: FakeDisk(free: free), cacheVolume: base,
            purgeCoreMLCache: { recorder.purge() }, log: { recorder.log($0) })
        let coreML = self.coreML
        return CompiledModelStore(
            root: root, coreML: guardian, version: version,
            compile: { try coreML.compile($0) }, load: { try coreML.load($0) })
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

    @Test("a load that keeps failing throws after the one retry")
    func persistentFailureThrows() throws {
        let f = try Fixture()
        defer { f.remove() }
        f.coreML.failNextLoads(10)
        #expect(throws: FakeCoreML.LoadFailed.self) { try f.store().model(package: f.package) }
        #expect(f.coreML.loads == 2)
        #expect(f.recorder.purgeCount == 1)
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

    @Test("legacy entries are swept, another bundle's entry and foreign files are kept")
    func sweepKeepsOtherBundles() throws {
        let f = try Fixture()
        defer { f.remove() }
        let other = f.base.appendingPathComponent("other/model.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try f.store().model(package: other)
        let otherEntries = try f.rootEntries()
        let legacy = f.root.appendingPathComponent("a7cf96588a1d54f5.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let foreign = f.root.appendingPathComponent("coreml-guard", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        _ = try f.store().model(package: f.package)
        let after = try f.rootEntries()
        #expect(!after.contains("a7cf96588a1d54f5.mlmodelc"))
        #expect(after.contains("coreml-guard"))
        #expect(Set(otherEntries).isSubset(of: after))
        #expect(after.count == otherEntries.count + 3)
    }

    @Test("a symlinked cache root is not used; the model still loads from the compile output")
    func symlinkedRootNotUsed() throws {
        let f = try Fixture()
        defer { f.remove() }
        let elsewhere = f.base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f.root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.root, withDestinationURL: elsewhere)
        #expect(try f.store().model(package: f.package) == "model")
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }
}
