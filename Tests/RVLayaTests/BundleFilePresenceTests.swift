#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
@testable import RVLaya

/// Only ENOENT is a missing bundle file; every other `lstat` error is an
/// unknown answer the judge must refuse on (review), never "absent".
@Suite("Bundle file presence")
struct BundleFilePresenceTests {
    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-bundle-presence-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("present, absent (ENOENT), and a dangling symlink counts as present")
    func presentAndAbsent() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tokenizer.json")
        try Data("{}".utf8).write(to: file)
        #expect(BundleFilePresence.of(file) == .present)
        #expect(BundleFilePresence.of(dir.appendingPathComponent("missing")) == .absent)
        #expect(BundleFilePresence.of(dir.appendingPathComponent("no/such/dir/file")) == .absent)
        let link = dir.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: dir.appendingPathComponent("nowhere"))
        #expect(BundleFilePresence.of(link) == .present)
    }

    @Test("ENOTDIR and ENAMETOOLONG are unknown, never absent")
    func otherErrorsAreUnknown() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tokenizer")
        try Data().write(to: file)
        guard case .unknown = BundleFilePresence.of(file.appendingPathComponent("tokenizer.json")) else {
            Issue.record("ENOTDIR read as \(BundleFilePresence.of(file.appendingPathComponent("tokenizer.json")))")
            return
        }
        let tooLong = URL(fileURLWithPath: "/" + String(repeating: "a", count: 300) + "/model.mlpackage")
        guard case .unknown = BundleFilePresence.of(tooLong) else {
            Issue.record("ENAMETOOLONG read as \(BundleFilePresence.of(tooLong))")
            return
        }
        #expect(throws: CoreMLLoadRefusal.self) { try BundleFilePresence.exists(tooLong) }
    }

    @Test("EACCES on the parent is unknown, never absent", .enabled(if: geteuid() != 0, "root searches mode-000 directories"))
    func permissionDeniedIsUnknown() throws {
        let dir = try Self.scratch()
        let locked = dir.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data().write(to: locked.appendingPathComponent("model.mlpackage"))
        chmod(locked.path, 0)
        defer {
            chmod(locked.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        guard case .unknown = BundleFilePresence.of(locked.appendingPathComponent("model.mlpackage")) else {
            Issue.record("EACCES read as absent or present")
            return
        }
    }

    #if canImport(CoreML)
    /// A tokenizer path the judge cannot check (here `tokenizer` is a file,
    /// so the nested path is ENOTDIR) refuses (review); it is not a
    /// missing tokenizer.
    @Test("FT load refuses when the tokenizer cannot be checked")
    func ftUncheckableTokenizerRefuses() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("model.mlpackage"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("tokenizer"))
        let guardian = CoreMLGuard(
            store: nil, disk: FakeDisk(free: 100 << 30), cacheVolume: nil,
            stateRoot: dir.appendingPathComponent("state"), purgeCoreMLCache: {}, log: { _ in })
        #expect(throws: CoreMLLoadRefusal.self) { _ = try FineTunedJudge(bundleDir: dir, coreML: guardian) }
    }

    /// No bundle at all is genuine absence on both engines; a bundle path
    /// that is a file (ENOTDIR below it) is not.
    @Test("an absent bundle is bundleMissing; an uncheckable one refuses")
    func absentBundleIsBundleMissing() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let guardian = CoreMLGuard(
            store: nil, disk: FakeDisk(free: 100 << 30), cacheVolume: nil,
            stateRoot: dir.appendingPathComponent("state"), purgeCoreMLCache: {}, log: { _ in })
        let absent = dir.appendingPathComponent("no-bundle", isDirectory: true)
        let loads: [(URL) throws -> Void] = [
            { _ = try FineTunedJudge(bundleDir: $0, coreML: guardian) },
            { _ = try LayaCoreMLJudge(bundleDir: $0, coreML: guardian) },
        ]
        for load in loads {
            #expect(throws: LayaError.bundleMissing("no bundle at \(absent.path)")) { try load(absent) }
        }
        let file = dir.appendingPathComponent("file")
        try Data().write(to: file)
        for load in loads {
            #expect(throws: CoreMLLoadRefusal.self) { try load(file.appendingPathComponent("bundle")) }
        }
    }

    /// A model package that is not there (ENOENT) is the one genuine
    /// absence: `bundleMissing`, the packs-only floor. Both engines.
    @Test("a missing model package is bundleMissing on both engines")
    func missingModelIsBundleMissing() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokenizer = Data(#"{"model":{"vocab":{},"merges":[]}}"#.utf8)
        try tokenizer.write(to: dir.appendingPathComponent("tokenizer.json"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("tokenizer"), withIntermediateDirectories: true)
        try tokenizer.write(to: dir.appendingPathComponent("tokenizer/tokenizer.json"))
        let guardian = CoreMLGuard(
            store: nil, disk: FakeDisk(free: 100 << 30), cacheVolume: nil,
            stateRoot: dir.appendingPathComponent("state"), purgeCoreMLCache: {}, log: { _ in })
        for load in [
            { _ = try FineTunedJudge(bundleDir: dir, coreML: guardian) },
            { _ = try LayaCoreMLJudge(bundleDir: dir, coreML: guardian) },
        ] as [() throws -> Void] {
            do {
                try load()
                Issue.record("expected bundleMissing")
            } catch LayaError.bundleMissing {
            } catch {
                Issue.record("expected bundleMissing, got \(error)")
            }
        }
    }
    #endif

    /// A tokenizer that is there but cannot be read is a bad bundle (the
    /// gate refuses on it), never a missing one.
    @Test("an unreadable tokenizer is badBundle, never bundleMissing")
    func unreadableTokenizerIsBadBundle() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokenizer = dir.appendingPathComponent("tokenizer.json", isDirectory: true)
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        #expect(throws: LayaError.badBundle("tokenizer.json unreadable at \(tokenizer.path)")) {
            _ = try LayaTokenizer(tokenizerJSON: tokenizer)
        }
    }
}
