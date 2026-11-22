import Foundation
import RVDomain
import RVPolicy
import RVPresentation
import RVService
import RVTheme
import RVTUI

public enum CLIKind: Equatable, Sendable {
    case test
    case testExplain
    case explain

    var exitsZeroOnDeny: Bool { self == .explain }
    var usesExplainFrame: Bool { self != .test }
}

public struct CLIResult: Equatable, Sendable {
    public var stdout: String
    public var exitCode: Int32

    public init(stdout: String, exitCode: Int32) {
        self.stdout = stdout
        self.exitCode = exitCode
    }
}

public enum CommandRun {
    public static func evaluateCommand(
        _ raw: String,
        cwd: String,
        store: AllowOnceStore,
        now: Date = Date(),
        home: HomeDirectory? = HomeDirectory.process()
    ) async -> EvaluationResult {
        await evaluateCommand(
            raw,
            cwd: WorkingDirectory(validating: cwd),
            store: store,
            now: now,
            home: home
        )
    }

    public static func evaluateCommand(
        _ raw: String,
        cwd: WorkingDirectory?,
        store: AllowOnceStore,
        now: Date = Date(),
        home: HomeDirectory? = HomeDirectory.process()
    ) async -> EvaluationResult {
        await LiveEvaluateWorld(home: home, store: store, clock: { now }).peek(
            command: ShellCommand(rawValue: raw),
            cwd: cwd
        )
    }

    public static func evaluateCommand(
        _ raw: String,
        cwd: String,
        allowOnceDirectory: URL,
        now: Date = Date(),
        home: HomeDirectory? = HomeDirectory.process()
    ) async -> EvaluationResult {
        await evaluateCommand(
            raw,
            cwd: WorkingDirectory(validating: cwd),
            store: AllowOnceStore(baseDirectory: allowOnceDirectory),
            now: now,
            home: home
        )
    }

    public static func evaluateCommand(
        _ raw: String,
        cwd: WorkingDirectory?,
        allowOnceDirectory: URL,
        now: Date = Date(),
        home: HomeDirectory? = HomeDirectory.process()
    ) async -> EvaluationResult {
        await evaluateCommand(
            raw,
            cwd: cwd,
            store: AllowOnceStore(baseDirectory: allowOnceDirectory),
            now: now,
            home: home
        )
    }

    public static func run(
        kind: CLIKind,
        command raw: String,
        probe: ThemeProbe,
        requested: RequestedMode,
        cwd: String,
        store: AllowOnceStore,
        now: Date = Date(),
        home: HomeDirectory? = HomeDirectory.process()
    ) async throws -> CLIResult {
        try await run(
            kind: kind,
            command: raw,
            probe: probe,
            requested: requested,
            cwd: WorkingDirectory(validating: cwd),
            store: store,
            now: now,
            home: home
        )
    }

    public static func run(
        kind: CLIKind,
        command raw: String,
        probe: ThemeProbe,
        requested: RequestedMode,
        cwd: WorkingDirectory?,
        store: AllowOnceStore,
        now: Date = Date(),
        home: HomeDirectory? = HomeDirectory.process()
    ) async throws -> CLIResult {
        let verdict = await LiveEvaluateWorld(home: home, store: store, clock: { now }).peekVerdict(
            command: ShellCommand(rawValue: raw),
            cwd: cwd
        )
        return try render(
            kind: kind,
            verdict: verdict,
            command: ShellCommand(rawValue: raw),
            probe: probe,
            requested: requested
        )
    }

    public static func run(
        kind: CLIKind,
        command raw: String,
        probe: ThemeProbe,
        requested: RequestedMode,
        cwd: String,
        allowOnceDirectory: URL,
        now: Date = Date(),
        home: HomeDirectory? = HomeDirectory.process()
    ) async throws -> CLIResult {
        try await run(
            kind: kind,
            command: raw,
            probe: probe,
            requested: requested,
            cwd: WorkingDirectory(validating: cwd),
            store: AllowOnceStore(baseDirectory: allowOnceDirectory),
            now: now,
            home: home
        )
    }

    public static func run(
        kind: CLIKind,
        command raw: String,
        probe: ThemeProbe,
        requested: RequestedMode,
        cwd: WorkingDirectory?,
        allowOnceDirectory: URL,
        now: Date = Date(),
        home: HomeDirectory? = HomeDirectory.process()
    ) async throws -> CLIResult {
        try await run(
            kind: kind,
            command: raw,
            probe: probe,
            requested: requested,
            cwd: cwd,
            store: AllowOnceStore(baseDirectory: allowOnceDirectory),
            now: now,
            home: home
        )
    }

    public static func render(
        kind: CLIKind,
        result: EvaluationResult,
        command: ShellCommand,
        probe: ThemeProbe,
        requested: RequestedMode
    ) throws -> CLIResult {
        try render(
            kind: kind,
            verdict: GatedVerdict(result: result),
            command: command,
            probe: probe,
            requested: requested
        )
    }

    /// Renders the verdict enforce would reach: under observe that is the
    /// would-be verdict (exit code included), and when observe let it run
    /// the output says so.
    package static func render(
        kind: CLIKind,
        verdict: GatedVerdict,
        command: ShellCommand,
        probe: ThemeProbe,
        requested: RequestedMode
    ) throws -> CLIResult {
        let result = verdict.shown
        // Watched: enforce's authorization of the would-be verdict, as the
        // observed denial row records it, when observe changed the outcome.
        // Stopped: observe was read but its floor kept the verdict. nil
        // under enforce, or for an allow.
        let authorization: ObserveOutcome?
        if verdict.stoppedInEveryMode {
            authorization = .stopped
        } else if verdict.observeOverrode, let wouldBe = verdict.wouldBe {
            authorization = .watched(wouldBe.authorization)
        } else {
            authorization = nil
        }
        let mode = OutputMode(probe: probe, requested: requested)
        let palette = Palette(for: ColorCapability(probe: probe, mode: mode), background: probe.background)
        let exitCode: Int32 = kind.exitsZeroOnDeny || result.decision == .allow ? 0 : 1

        if mode == .robot {
            return try robotResult(
                kind: kind, result: result, observed: authorization, command: command, exitCode: exitCode
            )
        }

        let lines = kind.usesExplainFrame
            ? ExplainRenderer().render(
                explainViewModel(
                    from: result,
                    command: command,
                    normalized: result.matchingView.rawValue,
                    observed: authorization
                ),
                palette: palette
            )
            : TestRenderer().render(
                testViewModel(from: result, command: command, columns: probe.columns, observed: authorization),
                palette: palette
            )
        return CLIResult(stdout: PrettyWriter.join(lines), exitCode: exitCode)
    }

    private static func robotResult(
        kind: CLIKind,
        result: EvaluationResult,
        observed: ObserveOutcome?,
        command: ShellCommand,
        exitCode: Int32
    ) throws -> CLIResult {
        // Schema follows the CLI verb, not pretty-frame choice: only `rv explain`
        // emits `rv.explain.v1`. `rv test` / `rv test --explain` keep `rv.test.v1`.
        let text: String
        switch kind {
        case .explain:
            let payload = explainRobotPayload(
                from: explainViewModel(
                    from: result,
                    command: command,
                    normalized: result.matchingView.rawValue,
                    observed: observed
                )
            )
            text = try RobotDocument.explain(payload).render()
        case .test, .testExplain:
            text = try RobotDocument.test(testRobotPayload(from: result, observed: observed)).render()
        }
        return CLIResult(stdout: text + "\n", exitCode: exitCode)
    }
}
