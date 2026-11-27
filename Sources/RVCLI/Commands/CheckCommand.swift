import ArgumentParser
import Foundation
import RVDomain
import RVPolicy
import RVService

/// `rv check "cmd" "cmd" …`: what rv would do with each step of a plan,
/// before an agent runs any of it (Everyday Magic, "Ask once for the
/// whole plan").
///
/// Read-only. Each step goes through the same peek `rv explain` uses: no
/// allow-once grant is spent, no denial row is written, and rvd is never
/// asked. It approves nothing either: a step that needs a person still
/// needs one when the agent runs it.
struct CheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check a plan's commands before an agent runs them."
    )

    @OptionGroup
    var format: FormatFlags

    @Argument(help: "Commands to check, one per argument. With none, one per line on stdin.")
    var commands: [String] = []

    func run() async throws {
        let ctx = CommandContext.current(command: "check", format: format)
        let steps: [String]
        switch CheckPlan.steps(
            arguments: commands,
            stdin: CLIProcess.stdinIsTTY() ? nil : CLIProcess.standardInputText()
        ) {
        case .success(let parsed):
            steps = parsed
        case .failure(let problem):
            try ctx.fail("rv check: \(problem.message)\n", exitCode: 64)
        }
        let report = await CheckRun.report(
            steps: steps,
            cwd: WorkingDirectory(validating: CLIProcess.workspacePath()),
            home: ctx.home
        )
        if ctx.explicitRobot {
            try ctx.emit(stdout: try RobotJSON.encode(report.robot) + "\n", exitCode: report.exitCode)
        }
        let palette = BoxInk.palette(isTerminal: CLIProcess.stdoutIsTTY(), environment: CLIProcess.environment())
        try ctx.emit(stdout: BoxInk.paint(report.text, palette: palette), exitCode: report.exitCode)
    }
}

/// The steps of a plan: the arguments, or the lines of stdin.
enum CheckPlan {
    /// More than this is not a plan an agent should ask about at once.
    static let maxSteps = 100
    /// A step longer than this is refused rather than checked in part.
    static let maxStepBytes = 16 * 1024

    struct Problem: Error, Equatable {
        let message: String
    }

    /// Arguments win. With none, every stdin line that is not blank or a
    /// `#` comment is one step.
    static func steps(arguments: [String], stdin: String?) -> Result<[String], Problem> {
        let raw: [String]
        if arguments.isEmpty {
            raw = (stdin ?? "").split(whereSeparator: \.isNewline).map(String.init)
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed.isEmpty == false && trimmed.hasPrefix("#") == false
                }
        } else {
            raw = arguments
        }
        let steps = raw.map { $0.trimmingCharacters(in: .whitespaces) }
        guard steps.isEmpty == false else {
            return .failure(Problem(message: "no commands to check. Pass each one in quotes, or one per line on stdin."))
        }
        guard steps.count <= maxSteps else {
            return .failure(Problem(message: "\(steps.count) steps is more than \(maxSteps). Check the plan in parts."))
        }
        if let index = steps.firstIndex(where: { $0.isEmpty }) {
            return .failure(Problem(message: "step \(index + 1) is empty."))
        }
        if let index = steps.firstIndex(where: { $0.utf8.count > maxStepBytes }) {
            return .failure(Problem(message: "step \(index + 1) is longer than \(maxStepBytes / 1024) KB."))
        }
        return .success(steps)
    }
}

/// What rv would do with one step.
enum CheckOutcome: String, Equatable, Sendable, Encodable {
    /// It would run.
    case fine
    /// Watch mode: guarding would stop it, but today it runs.
    case wouldStop = "would_stop"
    /// A person has to approve it when it runs.
    case asks
    /// rv would stop it.
    case stops
    /// rv could not finish checking it, so it would be refused.
    case incomplete

    var glyph: CommandVocabulary.Glyph {
        switch self {
        case .fine: .done
        case .wouldStop: .watched
        case .asks: .ask
        case .stops, .incomplete: .stopped
        }
    }

    /// Needs a person before it can run.
    var needsPerson: Bool { self == .asks || self == .stops || self == .incomplete }

    /// The verdict as `rv check` reports it. Under watch mode the shown
    /// result is what guarding would do; when watch let it run, the step
    /// is a would-stop.
    init(verdict: GatedVerdict, cwd: WorkingDirectory?) {
        let shown = verdict.shown
        switch shown.decision {
        case .allow:
            self = .fine
        case .indeterminate:
            self = .incomplete
        case .deny:
            if verdict.observeOverrode {
                self = .wouldStop
            } else {
                self = HookAuthorization.project(result: shown, cwd: cwd) == .ask ? .asks : .stops
            }
        }
    }
}

struct CheckStep: Equatable, Sendable {
    var command: String
    var outcome: CheckOutcome
    var rule: String?
    /// Why, in one sentence; nil for a fine step.
    var reason: String?
}

enum CheckRun {
    /// Every step through the explain peek, in order.
    static func report(steps: [String], cwd: WorkingDirectory?, home: HomeDirectory?, now: Date = Date()) async -> CheckReport {
        let world = LiveEvaluateWorld(home: home, store: CommandInvocation.allowOnceStore(home: home), clock: { now })
        var checked: [CheckStep] = []
        for step in steps {
            let verdict = await world.peekVerdict(command: ShellCommand(rawValue: step), cwd: cwd)
            checked.append(Self.step(step, verdict: verdict, cwd: cwd))
        }
        return CheckReport(steps: checked)
    }

    static func step(_ command: String, verdict: GatedVerdict, cwd: WorkingDirectory?) -> CheckStep {
        let outcome = CheckOutcome(verdict: verdict, cwd: cwd)
        switch verdict.shown.decision {
        case .allow:
            return CheckStep(command: command, outcome: outcome)
        case .deny(let deny):
            return CheckStep(command: command, outcome: outcome, rule: deny.ruleID.rawValue, reason: firstSentence(deny.reason))
        case .indeterminate(let reason):
            return CheckStep(command: command, outcome: outcome, rule: nil, reason: firstSentence(indeterminateSentence(reason)))
        }
    }

    /// The first sentence, so one step stays one line.
    static func firstSentence(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if let end = flat.range(of: ". ") { return String(flat[..<end.lowerBound]) }
        return flat.hasSuffix(".") ? String(flat.dropLast()) : flat
    }
}

/// A checked plan, as text and as `rv.check.v1` JSON.
struct CheckReport: Equatable, Sendable {
    /// Widest command column before the reason; longer commands are cut.
    static let commandColumn = 44

    var steps: [CheckStep]

    /// 0 when nothing needs a person (watch-mode would-stops still run),
    /// 1 when a step would be stopped, asks, or could not be checked.
    var exitCode: Int32 { steps.contains { $0.outcome.needsPerson } ? 1 : 0 }

    var text: String {
        let fine = steps.filter { $0.outcome == .fine }.count
        let person = steps.filter { $0.outcome.needsPerson }.count
        let watched = steps.filter { $0.outcome == .wouldStop }.count
        var summary = ["\(steps.count) \(steps.count == 1 ? "step" : "steps")", "\(fine) fine"]
        if person > 0 { summary.append("\(person) \(person == 1 ? "needs" : "need") a person") }
        if watched > 0 { summary.append("\(watched) watched") }
        var lines = ["\(CommandVocabulary.Glyph.rv.rawValue) " + summary.joined(separator: " · ")]
        let shown = steps.map { Self.clip(DisplayedText.field($0.command)) }
        let width = shown.map(\.count).max() ?? 0
        for (step, command) in zip(steps, shown) {
            var line = "  \(step.outcome.glyph.rawValue) \(command)"
            if let note = Self.note(step) {
                line += String(repeating: " ", count: width - command.count) + "   " + note
            }
            lines.append(line)
        }
        if let first = steps.first(where: { $0.outcome != .fine }) {
            lines.append("\(CommandVocabulary.Glyph.next.rawValue) \(CommandVocabulary.Command.explain.invocation) '\(Self.quoted(first.command))'   why, step by step")
        }
        if person > 0 {
            lines.append("  rv check approves nothing: a person still decides those steps when they run.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    var robot: Robot {
        Robot(steps: steps.map { step in
            Robot.Step(command: step.command, outcome: step.outcome, rule: step.rule, reason: step.reason)
        })
    }

    struct Robot: Encodable, Equatable {
        let schema = "rv.check.v1"
        var steps: [Step]

        struct Step: Encodable, Equatable {
            var command: String
            var outcome: CheckOutcome
            var rule: String?
            var reason: String?
        }
    }

    private static func note(_ step: CheckStep) -> String? {
        guard let reason = step.reason.map(DisplayedText.field) else { return nil }
        switch step.outcome {
        case .fine: return nil
        case .wouldStop: return "would stop · runs in watch mode · \(reason)"
        case .asks: return "asks a person · \(reason)"
        case .stops, .incomplete: return reason
        }
    }

    private static func clip(_ text: String) -> String {
        text.count <= commandColumn ? text : String(text.prefix(commandColumn - 1)) + "…"
    }

    /// The command inside single quotes, as a shell reads it back.
    private static func quoted(_ command: String) -> String {
        DisplayedText.field(command).replacingOccurrences(of: "'", with: "'\\''")
    }
}
