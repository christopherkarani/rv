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
        let command = ShellCommand(rawValue: raw)
        do {
            let packs = try PackRegistry.loadDayOne()
            let engine = ICUPatternEngine()
            let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
            return evaluate(
                EvaluationRequest(command: command, enabledPacks: dayOnePackIDs),
                packs: packs,
                patterns: engine,
                compiled: compiled
            )
        } catch {
            return EvaluationResult(decision: .indeterminate(.corePacksUnavailable))
        }
    }

    public static func run(
        kind: CLIKind,
        command raw: String,
        probe: ThemeProbe,
        requested: RequestedMode
    ) -> CLIResult {
        let command = ShellCommand(rawValue: raw)
        let result = evaluateCommand(raw)
        return render(kind: kind, result: result, command: command, probe: probe, requested: requested)
    }

    public static func render(
        kind: CLIKind,
        result: EvaluationResult,
        command: ShellCommand,
        probe: ThemeProbe,
        requested: RequestedMode
    ) -> CLIResult {
        let mode = OutputModeResolver.resolve(probe: probe, requested: requested)
        let palette = palette(for: colorCapability(probe: probe, mode: mode))
        let exitCode: Int32
        switch kind {
        case .explain:
            exitCode = 0
        case .test, .testExplain:
            exitCode = result.decision == .allow ? 0 : 1
        }

        if mode == .robot {
            return CLIResult(stdout: RobotWriter.line(result: result, command: command), exitCode: exitCode)
        }

        let lines: [String]
        switch kind {
        case .test:
            switch result.decision {
            case .allow:
                lines = prettyAllowLines()
            case .deny:
                if let vm = denyViewModel(from: result, command: command) {
                    lines = DenyRenderer().render(vm, palette: palette)
                } else {
                    lines = prettyAllowLines()
                }
            case .indeterminate:
                lines = [hostDenyText(from: result, command: command) ?? incompleteEvalSentence]
            }
        case .testExplain, .explain:
            let vm = explainViewModel(
                from: result,
                command: command,
                normalized: Normalize.matchingView(of: command.rawValue)
            )
            lines = ExplainRenderer().render(vm, palette: palette)
        }
        return CLIResult(stdout: PrettyWriter.join(lines), exitCode: exitCode)
    }
}
