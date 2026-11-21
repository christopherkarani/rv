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
        #expect(load.reason.hasPrefix("Laya judge: Core ML could not compile or load the judge model"))
        #expect(load.reason.contains("LoadFailed()"))
        #expect(load.reason.contains("judged calls go to review"))
        #expect(load.reason.contains("Run `rv doctor`"))
    }

    @Test("a nested symlink in the compile output refuses")
    func nestedSymlinkRefuses() throws {
        let f = try Fixture()
        defer { f.remove() }
        let coreML = f.coreML
        let target = f.base.appendingPathComponent("outside.bin")
        try Data("evil!".utf8).write(to: target)
        let store = f.store(compile: { package in
            let out = try coreML.compile(package)
            try FileManager.default.createSymbolicLink(
                at: out.appendingPathComponent("weights/link.bin"), withDestinationURL: target)
            return out
        })
        #expect(throws: CompiledModelRefusal.self) { try store.model(package: f.package) }
        #expect(f.coreML.loads == 0)
        #expect(try f.tempEntries().isEmpty)
        #expect(try f.rootEntries().isEmpty)
    }

    @Test("a FIFO in the compile output refuses without blocking")
    func fifoRefuses() throws {
        let f = try Fixture()
        defer { f.remove() }
        let coreML = f.coreML
        let store = f.store(compile: { package in
            let out = try coreML.compile(package)
            #expect(mkfifo(out.appendingPathComponent("weights/pipe").path, 0o600) == 0)
            return out
        })
        #expect(throws: CompiledModelRefusal.self) { try store.model(package: f.package) }
        #expect(f.coreML.loads == 0)
        #expect(try f.tempEntries().isEmpty)
        #expect(try f.rootEntries().isEmpty)
    }

    @Test("the store root is made owner-only, and the installed copy is 0700/0600 whatever Core ML wrote")
    func installedTreeIsOwnerOnly() throws {
        let f = try Fixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(
            at: f.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let coreML = f.coreML
        let store = f.store(compile: { package in
            let out = try coreML.compile(package)
            chmod(out.appendingPathComponent("weights").path, 0o777)
            chmod(out.appendingPathComponent("model.mil").path, 0o666)
            return out
        })
        #expect(try store.model(package: f.package) == "model")
        #expect(try Self.mode(f.root) == 0o700)
        let entry = try #require(try f.rootEntries().first { $0.hasSuffix(".mlmodelc") })
        let dir = f.root.appendingPathComponent(entry)
        #expect(try Self.mode(dir) == 0o700)
        #expect(try Self.mode(dir.appendingPathComponent("weights")) == 0o700)
        #expect(try Self.mode(dir.appendingPathComponent("model.mil")) == 0o600)
        #expect(try Self.mode(dir.appendingPathComponent("weights/weight.bin")) == 0o600)
    }

    static func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return info.st_mode & 0o7777
    }

    @Test("only ENOENT is a missing model; any other lstat error refuses")
    func packagePresence() throws {
        let f = try Fixture()
        defer { f.remove() }
        #expect(try CompiledModelStore<String>.packageExists(f.package) == true)
        #expect(try CompiledModelStore<String>.packageExists(f.base.appendingPathComponent("absent")) == false)
        // One component over NAME_MAX (255 on Darwin and Linux) is
        // ENAMETOOLONG on both; a long path alone is not (Linux PATH_MAX is 4096).
        let tooLong = URL(fileURLWithPath: "/" + String(repeating: "a", count: 300) + "/model.mlpackage")
        #expect(throws: CoreMLLoadRefusal.self) { try CompiledModelStore<String>.packageExists(tooLong) }
    }

    @Test("a refused presence check is recorded on the guard for doctor")
    func presenceRefusalIsRecorded() throws {
        let f = try Fixture()
        defer { f.remove() }
        let coreML = f.store().coreML
        let tooLong = URL(fileURLWithPath: "/" + String(repeating: "a", count: 300) + "/model.mlpackage")
        #expect(throws: CoreMLLoadRefusal.self) {
            try CompiledModelStore<String>.packageExists(tooLong, recordingOn: coreML)
        }
        let reason = try #require(coreML.status.lastRefusal)
        #expect(reason.contains("cannot check model.mlpackage"))
    }

    @Test("a refusal is recorded on the guard for doctor, and cleared by the next good load")
    func lastRefusalIsRecorded() throws {
        let f = try Fixture()
        defer { f.remove() }
        let failing = f.store(digest: { _ in nil })
        #expect(throws: CompiledModelRefusal.self) { try failing.model(package: f.package) }
        let reason = try #require(failing.coreML.status.lastRefusal)
        #expect(reason.contains("could not hash the compiled model"))
        let good = CompiledModelStore(
            root: failing.root, coreML: failing.coreML, version: failing.version,
            compile: f.store().compile, load: f.store().load, digest: contentDigest)
        #expect(try good.model(package: f.package) == "model")
        #expect(failing.coreML.status.lastRefusal == nil)
    }

    @Test("two loaders at once compile once and both load the verified entry")
    func concurrentLoadersCompileOnce() throws {
        let f = try Fixture()
        defer { f.remove() }
        let results = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            let loaded = (try? f.store().model(package: f.package)) ?? "refused"
            results.withLock { $0.append(loaded) }
        }
        #expect(results.withLock { $0 } == Array(repeating: "model", count: 4))
        #expect(f.coreML.compiles == 1)
        #expect(!(try f.rootEntries()).contains { $0.contains(".partial-") })
    }

    @Test("the store lock lives beside the root, never inside it")
    func lockBesideRoot() throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.store().model(package: f.package)
        #expect(!(try f.rootEntries()).contains { $0.hasSuffix(".lock") })
        let parent = f.root.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent("rv-laya.lock").path))
    }

    @Test("a symlinked store lock refuses (review)")
    func symlinkedLockRefuses() throws {
        let f = try Fixture()
        defer { f.remove() }
        let parent = f.root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = f.base.appendingPathComponent("elsewhere")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: parent.appendingPathComponent("rv-laya.lock"), withDestinationURL: target)
        #expect(throws: CompiledModelRefusal.self) { try f.store().model(package: f.package) }
        #expect(f.coreML.compiles == 0)
    }

    @Test("a superseded entry another loader still holds is kept, and swept once released")
    func heldEntryNotSwept() throws {
        let f = try Fixture()
        defer { f.remove() }
        var held: (model: String, lease: CompiledModelLease)? = try f.store(version: "26A428").leasedModel(package: f.package)
        let old = try f.rootEntries()
        #expect(held?.model == "model")
        _ = try f.store(version: "26B100").model(package: f.package)
        #expect(Set(old).isSubset(of: try f.rootEntries()), "a loaded entry is never removed under its loader")
        held = nil
        _ = try f.store(version: "26C200").model(package: f.package)
        let after = try f.rootEntries()
        #expect(Set(old).isDisjoint(with: after))
        #expect(after.count == 2)
    }

    @Test("a failed load's retry never deletes an entry another loader holds")
    func retryKeepsHeldEntry() throws {
        let f = try Fixture()
        defer { f.remove() }
        let held = try f.store().leasedModel(package: f.package)
        f.coreML.failNextLoads(1)
        #expect(try f.store().model(package: f.package) == "model")
        #expect(f.coreML.compiles == 1, "the held entry was reloaded, not discarded and recompiled")
        withExtendedLifetime(held) {}
    }
}
