#if canImport(CoreML)
import CoreML
import Foundation
import Testing
@testable import RVLaya

private func guardBundleURL() -> URL? {
    ProcessInfo.processInfo.environment["RV_FT_BUNDLE"].map(URL.init(fileURLWithPath:))
}

/// The CPU-only fallback against the real fine-tuned model: after two
/// recorded Core ML crashes the judge loads `.cpuOnly` and still scores.
/// Set RV_FT_BUNDLE to run; skipped otherwise.
@Suite("Core ML guard (CoreML, bundle-gated)", .enabled(if: guardBundleURL() != nil))
struct CoreMLGuardBundleTests {
    /// Pins why rvd does not set TMPDIR: Core ML compiles into the per-user
    /// temp dir from `confstr`, whatever TMPDIR says. If this ever fails,
    /// Core ML honours TMPDIR and rvd can point it at a protected dir.
    @Test("Core ML compiles into the per-user temp dir, ignoring TMPDIR")
    func compileIgnoresTMPDIR() throws {
        let bundle = try #require(guardBundleURL())
        let state = try Self.tempState()
        defer { try? FileManager.default.removeItem(at: state) }
        let previous = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", state.path + "/", 1)
        defer { if let previous { setenv("TMPDIR", previous, 1) } else { unsetenv("TMPDIR") } }
        let compiled = try MLModel.compileModel(at: bundle.appendingPathComponent("model.mlpackage"))
        defer { try? FileManager.default.removeItem(at: compiled) }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        try #require(confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0)
        let userTemp = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        let parent = compiled.deletingLastPathComponent().resolvingSymlinksInPath().path
        #expect(parent == userTemp)
        #expect(parent != state.path)
    }

    @Test("a tripped guard loads CPU only and the judge still blocks")
    func cpuOnlyJudgeStillScores() throws {
        let bundle = try #require(guardBundleURL())
        let state = try Self.tempState()
        defer { try? FileManager.default.removeItem(at: state) }
        let store = FakeCrashStore()
        store.saveState(CoreMLCrashState(crashes: [], cpuOnlyUntil: Date().addingTimeInterval(3600)))
        let guardian = CoreMLGuard(
            store: store, disk: StatfsDiskSpace(), cacheVolume: CoreMLGuard.cachesRoot(),
            stateRoot: state, purgeCoreMLCache: {}, log: { _ in })
        #expect(guardian.computeUnits == .cpuOnly)
        let judge = try FineTunedJudge(bundleDir: bundle, coreML: guardian)
        _ = try judge.judge("ls -la")
        let verdict = try judge.judge("rm -rf ~/")
        #expect(verdict.action() == .block)
        print("cpu-only rm -rf latency ms: \(verdict.latencyMilliseconds)")
        #expect(store.marker == false)
    }

    @Test("the real bundle installs once into the verified store, reloads from it, and leaves no temp output")
    func realBundleInstallsAndReloads() throws {
        let bundle = try #require(guardBundleURL())
        let state = try Self.tempState()
        defer { try? FileManager.default.removeItem(at: state) }
        let guardian = CoreMLGuard(
            store: nil, disk: StatfsDiskSpace(), cacheVolume: nil,
            stateRoot: state, purgeCoreMLCache: {}, log: { _ in })
        let before = Self.tempCompileOutputs()
        _ = try FineTunedJudge(bundleDir: bundle, coreML: guardian)
        let models = state.appendingPathComponent("models", isDirectory: true)
        let installed = try FileManager.default.contentsOfDirectory(atPath: models.path).sorted()
        #expect(installed.count == 2, "one entry plus its manifest: \(installed)")
        #expect(!installed.contains { $0.hasPrefix(".partial-") })
        let entry = try #require(installed.first { $0.hasSuffix(".mlmodelc") })
        let firstInstall = try Self.modified(models.appendingPathComponent(entry))

        let verdict = try FineTunedJudge(bundleDir: bundle, coreML: guardian).judge("rm -rf ~/")
        #expect(verdict.action() == .block)
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path).sorted() == installed)
        #expect(try Self.modified(models.appendingPathComponent(entry)) == firstInstall, "reused, not recompiled")
        // $TMPDIR is shared; only compile outputs this test could have left count.
        #expect(Self.tempCompileOutputs().subtracting(before).isEmpty)
    }

    static func tempState() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-guard-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    static func tempCompileOutputs() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(names.filter { $0.hasPrefix("model_") && $0.hasSuffix(".mlmodelc") })
    }

    static func modified(_ url: URL) throws -> Date {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }
}
#endif
