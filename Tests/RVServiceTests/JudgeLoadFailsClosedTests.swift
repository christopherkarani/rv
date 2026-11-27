#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
@testable import RVService
import RVDomain
import RVIPC
import RVJudgePool
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
            // Agent-visible: no repair for the agent to attempt itself.
            #expect(!why.contains("install script"), "\(why)")
            #expect(!why.contains("to see the repair"), "\(why)")
            #expect(!why.contains("chmod"), "\(why)")
            #expect(why.contains("Ask the owner to run `rv doctor`"), "\(why)")
        }
        guard case .refused(let bad) = JudgeRuntime.loadFailureRun(LayaError.badBundle("config.json unreadable")) else {
            Issue.record("badBundle must refuse")
            return
        }
        #expect(bad.contains("config.json unreadable"))
        #expect(bad.contains("rv doctor"))
        guard case .unavailable = JudgeRuntime.loadFailureRun(LayaError.bundleMissing("no bundle")) else {
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

    /// Only a bundle dir that is itself absent (ENOENT) is unselected. One
    /// that is there in any form (empty, model without tokenizer, a symlink
    /// to nowhere) is a broken install: selected, so its load refuses.
    @Test(arguments: [JudgeEngine.ft, .laya])
    func onlyAnAbsentBundleDirIsNotSelected(engine: JudgeEngine) throws {
        try Self.withHome { home, models in
            let dir = try #require(JudgeRuntime.expectedBundleDir(engine: engine, home: home))
            let probe = { engine == .ft ? JudgeRuntime.ftBundleDir(home: home) : JudgeRuntime.bundleDir(home: home) }
            #expect(probe() == nil)
            try FileManager.default.createSymbolicLink(
                at: dir, withDestinationURL: models.appendingPathComponent("nowhere"))
            #expect(probe() == dir, "a dangling symlink bundle dir is not absence")
            try FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            #expect(probe() == dir, "an empty bundle dir is not absence")
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("model.mlpackage"), withIntermediateDirectories: true)
            #expect(probe() == dir, "a model without a tokenizer is not absence")
        }
    }

    /// A broken FT install refuses; it never falls back to the stock
    /// bundle (which would hand the decision to a different judge).
    @Test("a broken FT dir is selected over an installed stock bundle")
    func brokenFTDoesNotFallBackToStock() throws {
        try Self.withHome { home, _ in
            let ft = try #require(JudgeRuntime.expectedBundleDir(engine: .ft, home: home))
            let stock = try #require(JudgeRuntime.expectedBundleDir(engine: .laya, home: home))
            try FileManager.default.createDirectory(
                at: stock.appendingPathComponent("model.mlpackage"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: stock.appendingPathComponent("tokenizer"), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: stock.appendingPathComponent("tokenizer/tokenizer.json"))
            #expect(JudgeRuntime.selection(home: home, config: GuardConfig()).engine == .laya)
            try FileManager.default.createDirectory(at: ft, withIntermediateDirectories: true)
            let selected = JudgeRuntime.selection(home: home, config: GuardConfig())
            #expect(selected.engine == .ft)
            #expect(selected.bundle == ft)
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

    /// A selected bundle that is gone entirely (ENOENT) is genuine absence:
    /// packs-only on both engines.
    @Test(arguments: [JudgeEngine.ft, .laya])
    func absentBundleStaysUnavailable(engine: JudgeEngine) throws {
        let (base, _) = try JudgeInvalidLabelsTests.fakeBundle(package: true, engine: engine)
        defer { try? FileManager.default.removeItem(at: base) }
        let run = JudgeInvalidLabelsTests.runFakeBundle(
            base.appendingPathComponent("gone", isDirectory: true),
            state: base.appendingPathComponent("state", isDirectory: true), engine: engine)
        guard case .unavailable = run else {
            Issue.record("expected .unavailable, got \(run)")
            return
        }
    }

    /// A bundle dir that is there but partly broken refuses on both engines:
    /// model present and tokenizer missing, tokenizer present and model
    /// missing, or a bundle dir that is a symlink to nowhere.
    @Test(arguments: [JudgeEngine.ft, .laya])
    func partlyBrokenBundleRefuses(engine: JudgeEngine) throws {
        let tokenizer = engine == .laya ? "tokenizer/tokenizer.json" : "tokenizer.json"
        let cases: [(String, (URL, URL) throws -> URL)] = [
            ("tokenizer missing", { _, bundle in
                try FileManager.default.removeItem(at: bundle.appendingPathComponent(tokenizer))
                return bundle
            }),
            ("model missing", { _, bundle in
                try FileManager.default.removeItem(at: bundle.appendingPathComponent("model.mlpackage"))
                return bundle
            }),
            ("dangling symlink", { base, _ in
                let link = base.appendingPathComponent("linked", isDirectory: true)
                try FileManager.default.createSymbolicLink(
                    at: link, withDestinationURL: base.appendingPathComponent("nowhere"))
                return link
            }),
        ]
        for (name, breakIt) in cases {
            let (base, bundle) = try JudgeInvalidLabelsTests.fakeBundle(package: true, engine: engine)
            defer { try? FileManager.default.removeItem(at: base) }
            let target = try breakIt(base, bundle)
            let run = JudgeInvalidLabelsTests.runFakeBundle(
                target, state: base.appendingPathComponent("state", isDirectory: true), engine: engine)
            guard case .refused = run else {
                Issue.record("\(name): expected .refused, got \(run)")
                continue
            }
        }
    }

    /// A worker's refusal reason is already a full sentence: the pool passes
    /// it through instead of wrapping it in a second one.
    @Test("a pool load refusal is not double-wrapped")
    func poolRefusalNotDoubleWrapped() {
        let reason = CoreMLLoadRefusal(detail: "x").reason
        guard case .refused(let why) = JudgeRuntime.read(.loadFailed(LoadFailure(kind: .modelUnavailable, message: reason))) else {
            Issue.record("a pool load failure must refuse")
            return
        }
        #expect(why == reason)
        guard case .refused(let wrapped) = JudgeRuntime.read(.loadFailed(LoadFailure(kind: .badBundle, message: "tokenizer missing"))) else {
            Issue.record("a pool load failure must refuse")
            return
        }
        #expect(wrapped.contains("tokenizer missing"))
        #expect(wrapped.contains("Ask the owner to run `rv doctor`"))
    }
    #endif

    #if canImport(CoreML)
    /// The owner-only fix for an unopenable model cache lives in doctor,
    /// never in the agent-visible refusal. Doctor names it whenever a bundle
    /// is selected: with the pool bound (rvd on macOS) or not, and for an
    /// invalid bundle too. The path is one shell word even with a quote and
    /// a space in it.
    @Test("doctor names the chmod for a model cache its owner cannot open, pool bound or not")
    func doctorNamesModelCacheFix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv judge's home \(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let cache = CoreMLGuard.modelRoot(
            stateRoot: CoreMLGuard.stateRoot(configDirectory: root.appendingPathComponent(".config/rv")))
        defer {
            chmod(cache.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        let home = try #require(HomePath(validating: root.path))
        let bundle = try #require(JudgeRuntime.expectedBundleDir(engine: .ft, home: home))
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("model.mlpackage"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("tokenizer.json"))
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        func check(poolBound: Bool) -> DoctorCheck {
            DoctorSnapshotBuilder.judgeCheck(home: home, circuit: .closed, poolBound: poolBound)
        }
        for bound in [false, true] {
            #expect(!check(poolBound: bound).message.contains("chmod"), "a usable cache adds no note")
        }
        chmod(cache.path, 0)
        for bound in [true, false] {
            let ok = check(poolBound: bound)
            #expect(ok.status == .warning)
            #expect(try Self.shellWord(afterChmodIn: ok.message) == cache.path, "\(ok.message)")
        }
        // A selected bundle that fails a check still loads through the cache.
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("tokenizer.json"))
        let invalid = check(poolBound: true)
        #expect(invalid.message.contains("bundle invalid"), "\(invalid.message)")
        #expect(try Self.shellWord(afterChmodIn: invalid.message) == cache.path, "\(invalid.message)")
    }

    /// The word doctor prints after `chmod 700 `, as `/bin/sh` reads it.
    static func shellWord(afterChmodIn message: String) throws -> String {
        let start = try #require(message.range(of: "`chmod 700 "))
        let end = try #require(message[start.upperBound...].firstIndex(of: "`"))
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "printf '%s' " + message[start.upperBound..<end]]
        let out = Pipe()
        shell.standardOutput = out
        try shell.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        #expect(shell.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }
    #endif

    #if canImport(CoreML)
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
