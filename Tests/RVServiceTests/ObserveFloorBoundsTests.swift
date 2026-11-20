import Foundation
import Testing
import RVDomain
import RVEngine
import RVPolicy
@testable import RVService

/// Observe-floor inputs under 64 KB that crashed rvd or blew the hook's
/// 8 s budget. Either leaves rvd unreachable, and an observe hook then
/// allows every later call unchecked. Each must finish fast or fail
/// closed (never an allow).
@Suite("Observe floor bounds")
struct ObserveFloorBoundsTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Loose so a starved CI pool does not flake; in a debug build the
    /// regressions ran 49 s to 292 s, the fixed code under 4 s.
    private static let wallClockBound = Duration.seconds(20)
    private static let allow = EvaluationResult(outcome: .plain)

    /// End to end, the way rvd serves it: a detached task on the
    /// cooperative pool. The chain once overflowed the stack and killed
    /// rvd, so the trailing `pkill rvd` ran unchecked.
    @Test("observe host: a deep xargs chain is held, not a crash")
    func deepXargsChainHeldOnObserveHost() async throws {
        let home = try observeHome()
        defer { remove(home) }
        let command = String(repeating: "xargs ", count: 600) + "true; pkill rvd"
        let result = await Task.detached {
            await GatedEvaluate().apply(
                command: ShellCommand(rawValue: command), cwd: nil, home: home,
                grants: EphemeralAllowOnceTable(), now: Self.now,
                allowlist: { .empty }, host: .hook(.claude)
            )
        }.value
        #expect(result.decision != .allow)
    }

    @Test("lifecycle floor: a deep xargs chain fails closed")
    func deepXargsChainFailsClosed() {
        let command = ShellCommand(rawValue: String(repeating: "xargs ", count: 600) + "true")
        let result = ObserveFloor.lifecycleFloor(Self.allow, command: command, home: nil, cwd: nil)
        #expect(result != nil)
        #expect(result?.decision != .allow)
    }

    @Test("lifecycle floor: each oversized repro finishes fast or fails closed", arguments: [
        "pkill-words", "kill-operands", "rm-words", "python-heredoc",
    ])
    func oversizedReprosAreBounded(name: String) throws {
        let command = ShellCommand(rawValue: repro(name))
        #expect(command.rawValue.utf8.count <= 65536, "\(name): \(command.rawValue.utf8.count) bytes")
        let home = try #require(HomeDirectory(validating: "/Users/agent"))
        let cwd = try #require(WorkingDirectory(rawValue: "/Users/agent/project"))
        let clock = ContinuousClock()
        var result: EvaluationResult?
        let elapsed = clock.measure {
            result = ObserveFloor.lifecycleFloor(Self.allow, command: command, home: home, cwd: cwd)
        }
        #expect(result?.decision != .allow, "\(name)")
        #expect(elapsed < Self.wallClockBound, "\(name): \(elapsed)")
    }

    /// Past the floor's work budget nothing more is read: an allow becomes
    /// "run it in Terminal", a deny or hold is kept.
    @Test("lifecycle floor: an exhausted budget never allows")
    func exhaustedBudgetFailsClosed() {
        let command = ShellCommand(rawValue: "echo hi")
        let spent = ObserveFloor.lifecycleFloor(Self.allow, command: command, home: nil, cwd: nil, budget: .zero)
        #expect(spent?.decision == .indeterminate(.observeUnanalyzable))
        #expect(ObserveFloor.lifecycleFloor(Self.allow, command: command, home: nil, cwd: nil) == nil)
    }

    private func repro(_ name: String) -> String {
        switch name {
        case "pkill-words":
            String(repeating: "pkill ", count: 2000)
        case "kill-operands":
            "kill " + Array(repeating: "1", count: 32000).joined(separator: " ")
        case "rm-words":
            "rm " + Array(repeating: "x", count: 32000).joined(separator: " ")
        default:
            "python3 - <<'EOF'\n"
                + (0..<2700).map { "d['k\($0)'] = 'v\($0)'" }.joined(separator: "\n")
                + "\nEOF"
        }
    }
}

private func observeHome() throws -> HomeDirectory {
    let home = try guardHome(mode: nil)
    let directory = RVPolicyPaths.configDirectory(home: home)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try #"{"guard":{"hosts":{"claude":"observe"}}}"#
        .write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    return home
}
