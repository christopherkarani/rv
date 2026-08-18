import RVDomain
import RVEngine
import RVPacks
import RVPresentation
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
        evaluationResult(catching: {
            let command = ShellCommand(rawValue: raw)
            let packs = try PackRegistry.loadDayOne()
            let engine = ICUPatternEngine()
            let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
            return evaluate(
                EvaluationRequest(command: command, enabledPacks: dayOnePackIDs),
                packs: packs,
                patterns: engine,
                compiled: compiled
            )
        })
    }

    // Domain has no compile-fail reason; pack/decode and compile stay fail-closed.
    static func evaluationResult(from error: Error) -> EvaluationResult {
        switch error {
        case is PackLoadError, is DecodingError:
            return EvaluationResult(decision: .indeterminate(.corePacksUnavailable))
        case is PatternCompileError:
            return EvaluationResult(decision: .indeterminate(.corePacksUnavailable))
        default:
            return EvaluationResult(decision: .indeterminate(.corePacksUnavailable))
        }
    }

    static func evaluationResult(catching operation: () throws -> EvaluationResult) -> EvaluationResult {
        do {
            return try operation()
        } catch {
            return evaluationResult(from: error)
        }
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
