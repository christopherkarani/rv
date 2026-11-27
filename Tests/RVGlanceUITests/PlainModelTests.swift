#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import Testing
import RVGlance
@testable import RVGlanceUI

/// The model works out the last stop's line once and keeps it for display.
@MainActor
struct PlainModelTests {
    @Test func theLastStopGetsItsLineInTheBackground() async throws {
        let model = GlanceModel(
            state: GlanceSamples.state(.guarding), now: GlanceSamples.now, calendar: GlanceSamples.calendar,
            explainer: Echo())
        #expect(model.lastStopPlain == nil)
        model.explainLastStop()
        for _ in 0..<200 where model.lastStopPlain == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.lastStopPlain == PlainLine(text: "Would echo git reset --hard", source: .onDevice))
    }

    /// Opt-in: `RV_PLAIN_ONDEVICE=1` runs Apple's on-device model once.
    /// Never needed in CI; skipped when the model is unavailable.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RV_PLAIN_ONDEVICE"] == "1"))
    func onDeviceModelExplainsResetHard() async {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), PlainOnDeviceExplainer.isAvailable else {
            print("plain: on-device model unavailable on this Mac")
            return
        }
        for command in ["git reset --hard", "docker system prune -af", "kubectl delete namespace staging"] {
            let request = PlainRequest(host: .claude, tool: .bash, text: command, outcome: .stopped)
            let started = ContinuousClock.now
            let raw = await PlainOnDeviceExplainer().explain(request)
            let line = await PlainFallback(primary: PlainOnDeviceExplainer()).explain(request)
            print("plain: \(command) -> direct [\(raw.source.rawValue)] \(raw.text) (\(ContinuousClock.now - started))")
            print("plain: \(command) -> shown [\(line.source.rawValue)] \(line.text)")
            #expect(!line.text.isEmpty)
        }
        #endif
    }
}

private struct Echo: PlainExplainer {
    func explain(_ request: PlainRequest) async -> PlainLine {
        PlainLine(text: "Would echo \(request.text)", source: .onDevice)
    }
}
#endif
