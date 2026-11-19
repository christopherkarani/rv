#if canImport(CoreML)
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
    @Test("a tripped guard loads CPU only and the judge still blocks")
    func cpuOnlyJudgeStillScores() throws {
        let bundle = try #require(guardBundleURL())
        let store = FakeCrashStore()
        store.saveState(CoreMLCrashState(crashes: [], cpuOnlyUntil: Date().addingTimeInterval(3600)))
        let guardian = CoreMLGuard(
            store: store, disk: StatfsDiskSpace(), cacheVolume: CoreMLGuard.cachesRoot(),
            purgeCoreMLCache: {}, log: { _ in })
        #expect(guardian.computeUnits == .cpuOnly)
        let judge = try FineTunedJudge(bundleDir: bundle, coreML: guardian)
        _ = try judge.judge("ls -la")
        let verdict = try judge.judge("rm -rf ~/")
        #expect(verdict.action() == .block)
        print("cpu-only rm -rf latency ms: \(verdict.latencyMilliseconds)")
        #expect(store.marker == false)
    }
}
#endif
