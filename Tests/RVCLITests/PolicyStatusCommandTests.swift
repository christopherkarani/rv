import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPolicy
import RVPresentation
import RVTheme
import Synchronization
@testable import RVCLI

/// `rv policy status` and `--wait`: rvd's own typed-policy load, reported;
/// a failed load is reported as failed (evaluation denies), never replaced.
@Suite("PolicyStatusCommand")
struct PolicyStatusCommandTests {
    @Test func isRegisteredUnderPolicy() {
        let children = Policy.configuration.subcommands.map { $0.configuration.commandName }
        #expect(children.contains("status"))
        let help = HelpDispatch.text(.policy, palette: colorOffPalette)
        #expect(help.contains("rv policy status [--json]"))
        // The usage row spells what the parser takes: apply needs a file.
        #expect(help.contains("rv policy apply <policy.toml> [--repo] [--save [--wait [--wait-timeout <seconds>]]]"))
    }

    @Test func cleanLoad_reportsRvdsRevision() async throws {
        try await withFixture { fixture in
            try fixture.store.saveMachine(PolicyDocument(rules: [denyReset]))
            let output = CLIOutputCapture()

            try await fixture.run(["status"], source: fixture.rvdAnswer, output: output)

            #expect(output.stdout.contains("policy: loaded (as rvd evaluates it)"))
            #expect(output.stdout.contains("machine: r1, 1 rule"))
            #expect(output.stdout.contains("repo:    empty, 0 rules"))
            #expect(output.stdout.contains("ceiling: none"))
            #expect(output.stdout.contains("effective rules: 1"))
        }
    }

    @Test func corruptPolicy_isFailedWithTheReason_exit1() async throws {
        try await withFixture { fixture in
            try FileManager.default.createDirectory(at: fixture.config, withIntermediateDirectories: true)
            try "[[rule]]\nverdict = nope\n".write(to: fixture.store.machineFileURL, atomically: true, encoding: .utf8)
            let output = CLIOutputCapture()

            await #expect(throws: ExitCode(1)) {
                try await fixture.run(["status"], source: fixture.rvdAnswer, output: output)
            }

            #expect(output.stdout.contains("policy: failed (as rvd evaluates it)"))
            #expect(output.stdout.contains("reason: machine policy.toml cannot be read or parsed"))
            #expect(output.stdout.contains("rv does not fall back to an earlier policy"))
        }
    }

    @Test func invalidCeiling_isFailed() async throws {
        try await withFixture { fixture in
            try FileManager.default.createDirectory(at: fixture.config, withIntermediateDirectories: true)
            try "verdict = allow\n".write(
                to: RVPolicyPaths.policyCeilingFile(inConfigDir: fixture.config), atomically: true, encoding: .utf8)
            let output = CLIOutputCapture()

            await #expect(throws: ExitCode(1)) {
                try await fixture.run(["status", "--json"], source: fixture.rvdAnswer, output: output)
            }

            let object = try jsonObject(output.stdout)
            #expect(object["state"] as? String == "failed")
            #expect(object["failure"] as? String == "ceiling-invalid")
            #expect(object["source"] as? String == "rvd")
        }
    }

    /// A hand-edited layer that asks where the ceiling denies loads, and the
    /// ceiling's deny holds: reported as loaded with the violation named.
    @Test func ceilingViolation_isLoadedAndNamed() async throws {
        try await withFixture { fixture in
            try FileManager.default.createDirectory(at: fixture.config, withIntermediateDirectories: true)
            try PolicyCeilingTOML.render(PolicyCeiling(rules: [denyReset])).write(
                to: RVPolicyPaths.policyCeilingFile(inConfigDir: fixture.config), atomically: true, encoding: .utf8)
            try PolicyDocumentTOML.render(PolicyDocument(rules: [askReset])).write(
                to: fixture.store.machineFileURL, atomically: true, encoding: .utf8)
            let output = CLIOutputCapture()

            try await fixture.run(["status"], source: fixture.rvdAnswer, output: output)

            #expect(output.stdout.contains("policy: loaded"))
            #expect(output.stdout.contains("exceeds the ceiling, whose verdict holds at evaluation"))
            #expect(output.stdout.contains("ceiling: 1 rule"))
        }
    }

    @Test func rvdUnavailable_runsTheSameLoadLocallyAndSaysSo() async throws {
        try await withFixture { fixture in
            let output = CLIOutputCapture()

            // Exit 3: a clean local load must not pass `rv policy status && …`.
            await #expect(throws: ExitCode(3)) {
                try await fixture.run(["status", "--json"], source: nil, output: output)
            }

            let object = try jsonObject(output.stdout)
            #expect(object["source"] as? String == "local")
            #expect(object["rvdUnavailable"] as? String == "rvd is not reachable from this context")
            #expect(object["state"] as? String == "loaded")
        }
    }

    /// `busy` is "rvd did not answer": the CLI's own view, exit 3.
    @Test func rvdBusy_isTheLocalView_exit3() async throws {
        try await withFixture { fixture in
            let output = CLIOutputCapture()
            let busy = ServiceClient.observation(.busy)

            await #expect(throws: ExitCode(3)) {
                try await fixture.run(["status", "--json"], source: { _, _ in busy }, output: output)
            }

            let object = try jsonObject(output.stdout)
            #expect(object["source"] as? String == "local")
            #expect(object["rvdUnavailable"] as? String == "rvd is busy with other status requests")
        }
    }

    /// Exit 3 wins over a failed local load: the report is the CLI's view,
    /// not what rvd enforces.
    @Test func rvdUnavailable_localFailedLoad_stillExits3() async throws {
        try await withFixture { fixture in
            try FileManager.default.createDirectory(at: fixture.config, withIntermediateDirectories: true)
            #expect(mkfifo(fixture.store.machineFileURL.path, 0o600) == 0)
            let output = CLIOutputCapture()

            await #expect(throws: ExitCode(3)) {
                try await fixture.run(["status"], source: nil, output: output)
            }

            #expect(output.stdout.contains("policy: failed (this CLI's view; rvd unavailable:"))
            #expect(output.stdout.contains(
                "reason: machine policy.toml cannot be read or parsed: not a regular file"))
        }
    }

    @Test func handEdit_isReportedAsUnrecordedAgainstTheHead() async throws {
        try await withFixture { fixture in
            try fixture.store.saveMachine(PolicyDocument(rules: [denyReset]))
            try PolicyDocumentTOML.render(PolicyDocument(rules: [askReset])).write(
                to: fixture.store.machineFileURL, atomically: true, encoding: .utf8)
            let output = CLIOutputCapture()

            try await fixture.run(["status"], source: fixture.rvdAnswer, output: output)

            #expect(output.stdout.contains("machine: unrecorded edit sha256:"))
            #expect(output.stdout.contains("(head r1)"))
        }
    }

    // MARK: --wait

    @Test func waitWithoutSave_isRejected() {
        #expect(throws: (any Error).self) { try Policy.Apply.parseAsRoot(["x.toml", "--wait"]) }
        #expect(throws: (any Error).self) { try PolicyRollbackCommand.parseAsRoot(["1", "--wait-timeout", "5"]) }
        #expect(throws: (any Error).self) {
            try PolicyDraftCommand.parseAsRoot(["--english", "x", "--save", "--wait", "--wait-timeout", "0"])
        }
    }

    @Test func wait_timesOutWhileRvdIsUnreachable() async {
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await PolicyLoadWait.run(
            layer: .machine, hash: "h", cwd: nil, timeout: .milliseconds(300), pollInterval: .milliseconds(50),
            observe: { _, _ in .unavailable("rvd is not running") })
        #expect(outcome == .timedOut(.unavailable("rvd is not running")))
        #expect(clock.now - started >= .milliseconds(300))
    }

    @Test func wait_returnsOnceRvdReportsTheSavedHash() async {
        let calls = Counter()
        // Generous: the wait returns on the third poll, and a starved test
        // pool (Linux CI) can delay a 10 ms poll sleep by seconds.
        let outcome = await PolicyLoadWait.run(
            layer: .repo, hash: "new", cwd: nil, timeout: .seconds(60), pollInterval: .milliseconds(10),
            observe: { _, _ in
                let hash = calls.next() < 2 ? "old" : "new"
                return .rvd(PolicyLoadStatus(
                    state: .loaded, repo: .init(hash: hash, ruleCount: 0, exceedsCeiling: false)))
            })
        #expect(outcome == .loaded)
        #expect(calls.value == 3)
    }

    @Test func wait_failsFastWhenRvdCannotLoad() async {
        let failed = PolicyLoadStatus(state: .failed, failure: .repoInvalid)
        let outcome = await PolicyLoadWait.run(
            layer: .machine, hash: "h", cwd: nil, timeout: .seconds(30),
            observe: { _, _ in .rvd(failed) })
        #expect(outcome == .failed(failed))
    }

    @Test func wait_timesOutWhileRvdKeepsReportingAnotherHash() async {
        let other = PolicyStatusObservation.rvd(PolicyLoadStatus(
            state: .loaded, machine: .init(hash: "old", ruleCount: 1, exceedsCeiling: false)))
        let calls = Counter()
        let outcome = await PolicyLoadWait.run(
            layer: .machine, hash: "new", cwd: nil, timeout: .milliseconds(300), pollInterval: .milliseconds(20),
            observe: { _, _ in
                _ = calls.next()
                return other
            })
        #expect(outcome == .timedOut(other))
        // Poll count depends on scheduling under a loaded test pool; only
        // that rvd was asked is certain.
        #expect(calls.value >= 1)
    }

    /// A slow rvd cannot carry the wait past its timeout: each call is
    /// bounded by what is left, never the full per-call 5 s. The bounds
    /// prove it; wall-clock elapsed would flake on a starved test pool.
    @Test func wait_boundsEachCallByWhatIsLeft() async {
        let bounds = Recorder<Duration>()
        let outcome = await PolicyLoadWait.run(
            layer: .machine, hash: "h", cwd: nil, timeout: .milliseconds(400), pollInterval: .milliseconds(10),
            observe: { _, bound in
                bounds.append(bound)
                // A transport that spends its whole bound, then gives up.
                try? await Task.sleep(for: bound)
                return .unavailable("request failed")
            })
        #expect(outcome == .timedOut(.unavailable("request failed")))
        #expect(bounds.values.isEmpty == false)
        #expect(bounds.values.allSatisfy { $0 <= .milliseconds(400) && $0 > .zero })
    }

    @Test func callTimeout_isCappedAtFiveSecondsAndNeverZero() {
        #expect(ServiceClient.policyStatusCallTimeoutMs(.seconds(30)) == 5_000)
        #expect(ServiceClient.policyStatusCallTimeoutMs(.milliseconds(1_250)) == 1_250)
        #expect(ServiceClient.policyStatusCallTimeoutMs(.zero) == 1)
    }

    @Test func applySaveWait_rvdCannotLoad_failsWithTheReason_exit1() async throws {
        try await withFixture { fixture in
            let share = try fixture.share([denyReset])
            let output = CLIOutputCapture()
            let failed = PolicyLoadStatus(state: .failed, failure: .repoInvalid)

            await #expect(throws: ExitCode(1)) {
                try await fixture.run(
                    ["apply", share.path, "--save", "--wait"], source: { _, _ in .rvd(failed) }, output: output)
            }

            #expect(output.stderr.contains(
                "rv policy apply: saved, but rvd cannot load policy: repo .rv/policy.toml cannot be read or parsed;"
                    + " every evaluation denies until it is fixed"))
            #expect(output.stdout.contains("rvd loaded") == false)
            #expect(try fixture.session.loadMachineDocument().rules.map(\.id) == [denyReset.id])
        }
    }

    @Test func applySaveWait_rvdKeepsAnotherHash_timesOutNamingIt() async throws {
        try await withFixture { fixture in
            let share = try fixture.share([denyReset])
            let output = CLIOutputCapture()
            let stale = PolicyLoadStatus(state: .loaded, machine: .init(hash: "old", ruleCount: 0, exceedsCeiling: false))

            await #expect(throws: ExitCode(1)) {
                try await fixture.run(
                    ["apply", share.path, "--save", "--wait", "--wait-timeout", "1"],
                    source: { _, _ in .rvd(stale) }, output: output)
            }

            #expect(output.stderr.contains(
                "rv policy apply: saved, but rvd did not confirm it within 1s (rvd still reports another machine policy)"))
        }
    }

    @Test func applySaveWait_confirmsWhenRvdLoadsIt() async throws {
        try await withFixture { fixture in
            let share = try fixture.share([denyReset])
            let output = CLIOutputCapture()

            try await fixture.run(
                ["apply", share.path, "--save", "--wait"], source: fixture.rvdAnswer, output: output)

            #expect(output.stdout.contains("rvd loaded the saved machine policy"))
        }
    }

    @Test func applySaveWait_timeoutExits1_andTheSaveStands() async throws {
        try await withFixture { fixture in
            let share = try fixture.share([denyReset])
            let output = CLIOutputCapture()

            await #expect(throws: ExitCode(1)) {
                try await fixture.run(
                    ["apply", share.path, "--save", "--wait", "--wait-timeout", "1"], source: nil, output: output)
            }

            #expect(output.stderr.contains(
                "rv policy apply: saved, but rvd did not confirm it within 1s (rvd is not reachable from this context)"))
            #expect(try fixture.session.loadMachineDocument().rules.map(\.id) == [denyReset.id])
        }
    }

    @Test func rollbackSaveWait_confirmsTheRestoredRevision() async throws {
        try await withFixture { fixture in
            try fixture.store.saveMachine(PolicyDocument(rules: [denyReset]))
            try fixture.store.saveMachine(PolicyDocument(rules: [denyReset, allowDiscard]))
            let output = CLIOutputCapture()

            try await fixture.run(["rollback", "1", "--save", "--wait"], source: fixture.rvdAnswer, output: output)

            #expect(output.stdout.contains("restored r1 as r3"))
            #expect(output.stdout.contains("rvd loaded the saved machine policy"))
        }
    }
}

// MARK: Fixture

private let denyReset = PolicyDocumentRule(
    id: RuleID(rawValue: "typed.git:no-reset")!, verdict: .deny, predicate: .gitReset(mode: nil))
private let askReset = PolicyDocumentRule(
    id: RuleID(rawValue: "typed.git:ask-reset")!, verdict: .ask, predicate: .gitReset(mode: nil))
private let allowDiscard = PolicyDocumentRule(
    id: RuleID(rawValue: "typed.git:discard-allow")!, verdict: .allow, predicate: .gitDiscardWorktree(pathspec: nil))

private final class Recorder<Value: Sendable>: Sendable {
    private let state = Mutex<[Value]>([])
    var values: [Value] { state.withLock { $0 } }
    func append(_ value: Value) { state.withLock { $0.append(value) } }
}

private final class Counter: Sendable {
    private let state = Mutex(0)
    var value: Int { state.withLock { $0 } }
    func next() -> Int { state.withLock { count in defer { count += 1 }; return count } }
}

private struct StatusFixture {
    let home: HomeDirectory
    let workspace: URL
    var config: URL { RVPolicyPaths.configDirectory(home: home) }
    var session: PolicyWorkspace { PolicyWorkspace(home: home, workspace: workspace) }
    var store: TypedRuleStore { TypedRuleStore(baseDirectory: config) }

    /// Stands in for rvd sharing this HOME: its answer is the same load.
    var rvdAnswer: PolicyStatusSource {
        let home = home
        return { cwd, _ in
            .rvd(PolicyWorkspace(home: home, workspace: cwd.map { URL(fileURLWithPath: $0.rawValue) }).loadStatus())
        }
    }

    func share(_ rules: [PolicyDocumentRule]) throws -> URL {
        let url = workspace.appendingPathComponent("share.toml")
        try PolicyDocumentTOML.render(PolicyDocument(rules: rules)).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func run(_ arguments: [String], source: PolicyStatusSource?, output: CLIOutputCapture) async throws {
        var context = CLIProcess.Context(
            home: home, stdinIsTTY: false, stdoutIsTTY: false, workspacePath: workspace.path,
            ownerAuthOutcome: .authenticated, output: output.sink)
        context.policyStatusSource = source
        try await CLIProcess.$context.withValue(context) {
            var command = try Policy.parseAsRoot(arguments)
            if var async = command as? AsyncParsableCommand {
                try await async.run()
            } else {
                try command.run()
            }
        }
    }
}

private func withFixture(_ body: (StatusFixture) async throws -> Void) async throws {
    let home = try isolatedHome()
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-status-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: home.rawValue, isDirectory: true))
        try? FileManager.default.removeItem(at: workspace)
    }
    try await body(StatusFixture(home: home, workspace: workspace))
}

private func jsonObject(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
