import Foundation
import Testing
import RVDomain
@testable import RVPolicy

struct NoBypassEnvTests {
    @Test func skipShapedEnvsDoNotSkipPolicy() async throws {
        let keys = [
            "RV_BYPASS", "RV_ALLOW", "RV_SKIP", "RV_DISABLE",
            "RV_NO_EVAL", "RV_ALLOW_ONCE", "RV_ALLOW_ONCE_SECRET",
        ]
        var previous: [String: String?] = [:]
        for key in keys {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, "1", 1)
        }
        defer {
            for (key, value) in previous {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        let store = AllowOnceStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-nobypass-\(UUID().uuidString)", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: store.baseDirectory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes"
                ),
                matched: nil
            ),
            matchingView: "git reset --hard"
        )
        let gated = await PolicyGate.apply(denied, cwd: "/tmp/a", store: store, now: now)
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("PolicyGate must still deny when skip-shaped envs are set")
            return
        }
    }
}
