import Foundation
import RVDomain
import RVEngine
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
        await EvaluationWorld.assemble(home: home, snapshots: nil, catalog: nil).run(
            .peek,
            command: ShellCommand(rawValue: raw),
            cwd: cwd,
            home: home,
            store: store,
            now: now
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
    ) async -> CLIResult {
        render(
            kind: kind,
            result: await evaluateCommand(raw, cwd: cwd, store: store, now: now, home: home),
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
    ) async -> CLIResult {
        await run(
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
    ) -> CLIResult {
        let mode = OutputMode(probe: probe, requested: requested)
        let palette = Palette(for: ColorCapability(probe: probe, mode: mode))
        let exitCode: Int32 = kind.exitsZeroOnDeny || result.decision == .allow ? 0 : 1

        if mode == .robot {
            return robotResult(kind: kind, result: result, command: command, exitCode: exitCode)
        }

        let lines = kind.usesExplainFrame
            ? ExplainRenderer().render(
                explainViewModel(
                    from: result,
                    command: command,
                    normalized: result.matchingView.isEmpty
                        ? Normalize.matchingView(of: command.rawValue).rawValue
                        : result.matchingView.rawValue
                ),
                palette: palette
            )
            : prettyTestLines(
                result: result,
                command: command,
                columns: probe.columns,
                palette: palette
            )
        return CLIResult(stdout: PrettyWriter.join(lines), exitCode: exitCode)
    }

    private static func robotResult(
        kind: CLIKind,
        result: EvaluationResult,
        command: ShellCommand,
        exitCode: Int32
    ) -> CLIResult {
        // Schema follows the CLI verb, not pretty-frame choice: only `rv explain`
        // emits `rv.explain.v1`. `rv test` / `rv test --explain` keep `rv.test.v1`.
        let text: String
        switch kind {
        case .explain:
            let payload = explainRobotPayload(
                from: explainViewModel(
                    from: result,
                    command: command,
                    normalized: result.matchingView.isEmpty
                        ? Normalize.matchingView(of: command.rawValue).rawValue
                        : result.matchingView.rawValue
                )
            )
            text = RobotDocument.explain(payload).render()
        case .test, .testExplain:
            text = RobotDocument.test(testRobotPayload(from: result)).render()
        }
        return CLIResult(stdout: text + "\n", exitCode: exitCode)
    }

    private static func prettyTestLines(
        result: EvaluationResult,
        command: ShellCommand,
        columns: Int,
        palette: Palette
    ) -> [String] {
        TestRenderer().render(
            testViewModel(from: result, command: command, columns: columns),
            palette: palette
        )
    }
}
