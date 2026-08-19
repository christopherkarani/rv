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
        now: Date = Date()
    ) async -> EvaluationResult {
        let engine = EvaluateSession().evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: raw),
                enabledPacks: dayOnePackIDs
            )
        )
        return await PolicyGate.peek(
            engine,
            cwd: cwd,
            store: store,
            now: now
        ).result
    }

    public static func evaluateCommand(
        _ raw: String,
        cwd: String,
        allowOnceDirectory: URL,
        now: Date = Date()
    ) async -> EvaluationResult {
        await evaluateCommand(
            raw,
            cwd: cwd,
            store: AllowOnceStore(baseDirectory: allowOnceDirectory),
            now: now
        )
    }

    public static func run(
        kind: CLIKind,
        command raw: String,
        probe: ThemeProbe,
        requested: RequestedMode,
        cwd: String,
        store: AllowOnceStore,
        now: Date = Date()
    ) async -> CLIResult {
        render(
            kind: kind,
            result: await evaluateCommand(raw, cwd: cwd, store: store, now: now),
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
        now: Date = Date()
    ) async -> CLIResult {
        await run(
            kind: kind,
            command: raw,
            probe: probe,
            requested: requested,
            cwd: cwd,
            store: AllowOnceStore(baseDirectory: allowOnceDirectory),
            now: now
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
            return CLIResult(stdout: RobotWriter.line(result: result), exitCode: exitCode)
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
