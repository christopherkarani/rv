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
        let alsoMatches = kind == .explain
            ? ExplainTypedRules.matches(result: verdict.shown, command: ShellCommand(rawValue: raw), cwd: cwd, home: home)
            : []
        let offPacks = kind == .explain
            ? ExplainOffPacks.hits(result: verdict.shown, command: ShellCommand(rawValue: raw), home: home)
            : []
        return try render(
            kind: kind,
            verdict: verdict,
            command: ShellCommand(rawValue: raw),
            probe: probe,
            requested: requested,
            alsoMatches: alsoMatches,
            offPacks: offPacks
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
        requested: RequestedMode,
        alsoMatches: [ExplainAlsoMatch] = [],
        offPacks: [ExplainOffPack] = []
    ) throws -> CLIResult {
        let result = verdict.shown
        let observed = verdict.observeOverrode
        // Enforce's authorization of the would-be verdict, as the observed
        // denial row records it; nil unless observe changed the outcome.
        let authorization = observed ? verdict.wouldBe?.authorization : nil
        let mode = OutputMode(probe: probe, requested: requested)
        let palette = Palette(for: ColorCapability(probe: probe, mode: mode), background: probe.background)
        let exitCode: Int32 = kind.exitsZeroOnDeny || result.decision == .allow ? 0 : 1

        if mode == .robot {
            return try robotResult(
                kind: kind, result: result, observed: authorization, command: command, exitCode: exitCode,
                alsoMatches: alsoMatches, offPacks: offPacks
            )
        }

        var explain = explainViewModel(
            from: result,
            command: command,
            normalized: result.matchingView.rawValue,
            observed: authorization
        )
        // The person's own rules that also match, which a pack deny hides.
        explain.alsoMatches = alsoMatches
        explain.offPacks = offPacks
        let lines = kind.usesExplainFrame
            ? ExplainRenderer().render(explain, palette: palette)
            : TestRenderer().render(
                testViewModel(from: result, command: command, columns: probe.columns, observed: authorization),
                palette: palette
            )
        return CLIResult(stdout: PrettyWriter.join(lines), exitCode: exitCode)
    }

    private static func robotResult(
        kind: CLIKind,
        result: EvaluationResult,
        observed: HookAuthorization?,
        command: ShellCommand,
        exitCode: Int32,
        alsoMatches: [ExplainAlsoMatch],
        offPacks: [ExplainOffPack]
    ) throws -> CLIResult {
        // Schema follows the CLI verb, not pretty-frame choice: only `rv explain`
        // emits `rv.explain.v1`. `rv test` / `rv test --explain` keep `rv.test.v1`.
        let text: String
        switch kind {
        case .explain:
            var model = explainViewModel(
                from: result,
                command: command,
                normalized: result.matchingView.rawValue,
                observed: observed
            )
            model.alsoMatches = alsoMatches
            model.offPacks = offPacks
            let payload = explainRobotPayload(from: model)
            text = try RobotDocument.explain(payload).render()
        case .test, .testExplain:
            text = try RobotDocument.test(testRobotPayload(from: result, observed: observed != nil)).render()
        }
        return CLIResult(stdout: text + "\n", exitCode: exitCode)
    }
}
