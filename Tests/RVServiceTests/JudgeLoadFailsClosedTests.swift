#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
@testable import RVService
import RVDomain
import RVLaya

/// `.unavailable` is the packs-only floor (an allow without a judge). It may
/// come only from genuine absence: no bundle installed, or no model in it
/// (ENOENT). A selected bundle that is there but cannot be checked, read or
/// loaded refuses (review).
@Suite("Judge load fails closed")
struct JudgeLoadFailsClosedTests {
    static func describe(_ run: JudgeRuntime.JudgeRun) -> String { "\(run)" }

    @Test("only bundleMissing reads as unavailable; every other load failure refuses or fails closed")
    func loadFailureMapping() {
        struct Unexpected: Error {}
        let refusing: [any Error] = [
            LayaError.badBundle("config.json unreadable"),
            LayaError.modelUnavailable("CoreML load failed"),
            Unexpected(),
            CoreMLLoadRefusal(detail: "cannot check model.mlpackage: Permission denied"),
        ]
        for error in refusing {
            guard case .refused(let why) = JudgeRuntime.loadFailureRun(error) else {
                Issue.record("\(error) must refuse, got \(Self.describe(JudgeRuntime.loadFailureRun(error)))")
                continue
            }
            #expect(why.contains("review"), "\(why)")
            #expect(!why.contains("install script"), "\(why)")
        }
        guard case .refused(let bad) = JudgeRuntime.loadFailureRun(LayaError.badBundle("config.json unreadable")) else {
            Issue.record("badBundle must refuse")
            return
        }
        #expect(bad.contains("config.json unreadable"))
        #expect(bad.contains("rv doctor"))
        guard case .unavailable = JudgeRuntime.loadFailureRun(LayaError.bundleMissing("no model")) else {
            Issue.record("bundleMissing is genuine absence: packs-only")
            return
        }
        guard case .failed = JudgeRuntime.loadFailureRun(LayaError.predictionFailed("x")) else {
            Issue.record("predictionFailed fails closed")
            return
        }
        guard case .warming = JudgeRuntime.loadFailureRun(JudgeLoadError.warming) else {
            Issue.record("warming stays warming")
            return
        }
    }

    static func withHome(_ body: (HomePath, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-judge-select-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            let models = root.appendingPathComponent(".config/rv/models")
            chmod(models.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        let home = try #require(HomePath(validating: root.path))
        let models = RVPolicyPathsProbe.models(home: home)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try body(home, models)
    }

    /// Selection: a bundle file the probe cannot check selects the bundle
    /// (so its load refuses); only ENOENT leaves it unselected.
    @Test(arguments: [JudgeEngine.ft, .laya])
    func uncheckableBundleIsSelected(engine: JudgeEngine) throws {
        try Self.withHome { home, models in
            let dir = try #require(JudgeRuntime.expectedBundleDir(engine: engine, home: home))
            let probe = { engine == .ft ? JudgeRuntime.ftBundleDir(home: home) : JudgeRuntime.bundleDir(home: home) }
            #expect(probe() == nil, "nothing installed is absence")
            // A regular file where the bundle dir belongs: every check under
            // it is ENOTDIR, not ENOENT.
            try Data().write(to: dir)
            #expect(probe() == dir, "ENOTDIR must not read as no bundle")
            try FileManager.default.removeItem(at: dir)
            // The model is there; the tokenizer path cannot be checked.
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("model.mlpackage"), withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent("tokenizer"))
            #expect(probe() == dir, "an uncheckable tokenizer must not read as missing")
            _ = models
        }
    }

    @Test("genuine absence stays unselected: no model, or model without any tokenizer")
    func genuineAbsenceIsNotSelected() throws {
        try Self.withHome { home, _ in
            let dir = try #require(JudgeRuntime.expectedBundleDir(engine: .ft, home: home))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            #expect(JudgeRuntime.ftBundleDir(home: home) == nil)
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("model.mlpackage"), withIntermediateDirectories: true)
            #expect(JudgeRuntime.ftBundleDir(home: home) == nil)
            try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
            #expect(JudgeRuntime.ftBundleDir(home: home) == dir)
        }
    }

    @Test(
        "a models dir the probe cannot search selects the bundle and doctor names it",
        .enabled(if: geteuid() != 0, "root searches mode-000 directories"))
    func unsearchableModelsDirIsSelected() throws {
        try Self.withHome { home, models in
            let dir = try #require(JudgeRuntime.expectedBundleDir(engine: .ft, home: home))
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("model.mlpackage"), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
            chmod(models.path, 0)
            defer { chmod(models.path, 0o700) }
            #expect(JudgeRuntime.selectsBundle(home: home))
            guard case .invalid(_, _, let problems) = JudgeRuntime.bundleHealth(home: home) else {
                Issue.record("an unsearchable bundle must be invalid for doctor")
                return
            }
            #expect(problems.contains { $0.contains("cannot be checked") }, "\(problems)")
        }
    }

    #if canImport(CoreML)
    /// End to end: the bundle selected above because its tokenizer path is
    /// ENOTDIR refuses on load; it never reaches the packs-only floor.
    @Test(arguments: [JudgeEngine.ft, .laya])
    func uncheckableTokenizerRefusesOnLoad(engine: JudgeEngine) throws {
        let (base, bundle) = try JudgeInvalidLabelsTests.fakeBundle(package: true, engine: engine)
        defer { try? FileManager.default.removeItem(at: base) }
        let tokenizer = bundle.appendingPathComponent("tokenizer")
        try? FileManager.default.removeItem(at: bundle.appendingPathComponent("tokenizer.json"))
        try? FileManager.default.removeItem(at: tokenizer)
        try Data().write(to: tokenizer)
        let run = JudgeInvalidLabelsTests.runFakeBundle(
            bundle, state: base.appendingPathComponent("state", isDirectory: true), engine: engine)
        guard case .refused = run else {
            Issue.record("expected .refused, got \(run)")
            return
        }
    }

    /// A tokenizer that is there but corrupt is a broken install, not an
    /// absent one: review, on both engines.
    @Test(arguments: [JudgeEngine.ft, .laya])
    func corruptTokenizerRefuses(engine: JudgeEngine) throws {
        let (base, bundle) = try JudgeInvalidLabelsTests.fakeBundle(package: true, engine: engine)
        defer { try? FileManager.default.removeItem(at: base) }
        let path = engine == .laya ? "tokenizer/tokenizer.json" : "tokenizer.json"
        try Data("not json".utf8).write(to: bundle.appendingPathComponent(path))
        let run = JudgeInvalidLabelsTests.runFakeBundle(
            bundle, state: base.appendingPathComponent("state", isDirectory: true), engine: engine)
        guard case .refused(let why) = run else {
            Issue.record("expected .refused, got \(run)")
            return
        }
        #expect(why.contains("tokenizer.json"))
    }
    #endif
}

/// The models dir under a test home (same layout as `expectedBundleDir`).
enum RVPolicyPathsProbe {
    static func models(home: HomePath) -> URL {
        URL(fileURLWithPath: home.rawValue, isDirectory: true)
            .appendingPathComponent(".config/rv/models", isDirectory: true)
    }
}
