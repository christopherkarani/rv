import RVDomain
import RVEngine
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
    public static func evaluateCommand(_ raw: String) -> EvaluationResult {
        EvaluateSession().evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: raw),
                enabledPacks: dayOnePackIDs
            )
        )
    }

    public static func run(
        kind: CLIKind,
        command raw: String,
        probe: ThemeProbe,
        requested: RequestedMode
    ) -> CLIResult {
        render(
            kind: kind,
            result: evaluateCommand(raw),
            command: ShellCommand(rawValue: raw),
            probe: probe,
            requested: requested
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
                    normalized: Normalize.matchingView(of: command.rawValue)
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
