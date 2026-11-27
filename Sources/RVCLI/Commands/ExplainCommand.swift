import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVPresentation
import RVService
import RVTheme
import RVTUI

struct Explain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Show why a command is allowed or blocked, or the story of a logged decision by its code."
    )

    @OptionGroup
    var format: FormatFlags

    @Argument(parsing: .captureForPassthrough, help: "Command to explain, or a code from rv log (a7c-835).")
    var commandParts: [String] = []

    func run() async throws {
        if let code = WhyRun.code(commandParts) {
            let ctx = CommandContext.current(command: "explain", format: format)
            let home = try ctx.requireHome()
            let outcome = try WhyRun.output(
                code: code, home: home, json: ctx.explicitRobot, palette: ctx.appearance.palette
            )
            try ctx.emit(stdout: outcome.stdout, exitCode: outcome.exitCode)
            return
        }
        try await CommandInvocation.emit(kind: .explain, commandParts: commandParts, format: format)
    }
}

/// `rv why <code>` (and `rv explain <code>`): one logged decision, told in
/// full from the rows rv keeps. Nothing is evaluated again, and every field
/// shown went through the log's redaction, so no secret value is printed.
enum WhyRun {
    struct Outcome: Equatable {
        var stdout: String
        var exitCode: Int32
    }

    /// The code when the arguments are exactly one `rv log` code: six hex
    /// digits, with or without the dash, any case (`a7c-835`, `A7C835`).
    static func code(_ parts: [String]) -> String? {
        guard parts.count == 1 else { return nil }
        let raw = parts[0].lowercased()
        let digits = raw.count == 7 && raw.dropFirst(3).first == "-"
            ? String(raw.prefix(3) + raw.suffix(3))
            : raw
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return String(digits.prefix(3)) + "-" + String(digits.suffix(3))
    }

    static func output(
        code: String, home: HomeDirectory, json: Bool, palette: Palette,
        now: Date = Date(), calendar: Calendar = .current,
        facts: (String) -> DecisionRuleFacts = PackRuleFacts.live
    ) throws -> Outcome {
        guard let story = story(code: code, home: home, now: now, calendar: calendar, facts: facts) else {
            if json {
                return Outcome(stdout: try RobotJSON.encode(NotFound(code: code)) + "\n", exitCode: 1)
            }
            return Outcome(
                stdout: PrettyWriter.join(DecisionStoryRenderer().renderNotFound(code: code, palette: palette)),
                exitCode: 1
            )
        }
        if json {
            return Outcome(stdout: try RobotJSON.encode(DecisionStoryRobotPayload(story)) + "\n", exitCode: 0)
        }
        return Outcome(stdout: PrettyWriter.join(DecisionStoryRenderer().render(story, palette: palette)), exitCode: 0)
    }

    /// The decision `code` names, from the same rows `rv log --all` reads
    /// (judge notes and self-protection included), or nil.
    static func story(
        code: String, home: HomeDirectory, now: Date, calendar: Calendar,
        facts: (String) -> DecisionRuleFacts
    ) -> DecisionStory? {
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        let records = DenialLedger(configDirectory: configDirectory).records(asOf: now)
        let decisions = LogRun.decisionLog(configDirectory: configDirectory, now: now)
        let entries = LogSources.entries(ledger: records, decisions: decisions, home: home)
        guard let entry = entries.filter({ $0.code == code }).max(by: { $0.time < $1.time }) else { return nil }
        let cwd = decisions?.records.first { $0.code == code }?.cwd
            .map { DecisionRedaction.path($0, home: home) }
        return DecisionStory(entry: entry, cwd: cwd, facts: facts(entry.rule), calendar: calendar)
    }

    private struct NotFound: Encodable {
        var schema = DecisionStoryRobotPayload.schema
        var code: String
        var found = false
    }
}

/// A rule's reason and guidance from the shipped packs. Reads pack JSON
/// only; nothing is compiled.
enum PackRuleFacts {
    static func live(_ rule: String) -> DecisionRuleFacts {
        guard let id = RuleID(rawValue: rule) else { return DecisionRuleFacts() }
        let facts = RuleFacts.lookup(id)
        return DecisionRuleFacts(reason: facts.reason, saferCommand: facts.saferCommand, whoActs: facts.whoActs)
    }
}
