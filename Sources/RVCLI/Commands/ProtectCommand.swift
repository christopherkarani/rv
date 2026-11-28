import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVService

/// `rv protect <tool>` and `rv protect <tool> off` (G6, Packs v6b): the
/// everyday front door for packs. Plain tool names (`redis`, `terraform`),
/// typos get the nearest name. Adding protection asks nobody, so an agent
/// can add it before risky work; the output offers the undo. Turning it
/// off needs the owner check (Touch ID or the login password), like
/// `rv packs disable`, and the hook guard refuses it from an agent.
struct Protect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: CommandVocabulary.Command.protect.rawValue,
        abstract: "Protect a tool (redis, terraform, docker...). Add off to remove it."
    )

    @Argument(help: "A tool name, such as redis or terraform, then off to remove protection.")
    var words: [String] = []

    func run() async throws {
        let request: ProtectRequest
        do {
            request = try ProtectRequest(words: words)
        } catch let refusal as ProtectRequest.Refusal {
            try CommandContext.fail(refusal.message)
        }
        let tools: ProtectTools
        do {
            tools = try ProtectTools.bundled()
        } catch {
            try CommandContext.fail("rv: the bundled packs cannot be read. Run rv doctor.\n")
        }
        let target = try resolve(request.tool, tools: tools, off: request.off)
        if request.off {
            try await ProtectFlow.turnOff(target)
        } else {
            try ProtectFlow.turnOn(target)
        }
    }

    /// A known name, or the nearest one when the person at a terminal
    /// confirms it. Never guesses for a script or an agent.
    private func resolve(_ tool: String, tools: ProtectTools, off: Bool) throws -> ProtectTarget {
        switch tools.resolve(tool) {
        case .found(let target):
            return target
        case .nearest(let target):
            if off == false, CLIProcess.stdinIsTTY(), CLIProcess.stdoutIsTTY() {
                CommandContext.writeStdout("  \(target.name)? ⏎ ")
                let answer = readAnswer().trimmingCharacters(in: .whitespaces).lowercased()
                if answer.isEmpty || answer == "y" || answer == "yes" { return target }
                try CommandContext.fail("  Nothing changed.\n")
            }
            try CommandContext.fail(ProtectText.nearest(typed: tool, target: target, off: off))
        case .unknown:
            try CommandContext.fail(ProtectText.unknown(typed: tool))
        }
    }
}

/// One line from the terminal (tests: the context's stdin text). No
/// input reads as no.
private func readAnswer() -> String {
    if let text = CLIProcess.context?.stdinText {
        return text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "n"
    }
    return readLine() ?? "n"
}

/// `rv protect` arguments: one tool name, and `off` anywhere to remove.
struct ProtectRequest: Equatable {
    struct Refusal: Error {
        let message: String
    }

    static let offWord = "off"

    var tool: String
    var off: Bool

    init(words: [String]) throws {
        let off = words.contains(Self.offWord)
        let names = words.filter { $0 != Self.offWord }
        guard names.count == 1, let tool = names.first else {
            let program = CommandVocabulary.Command.protect.invocation
            throw Refusal(message: names.isEmpty
                ? "rv: name a tool to protect, such as redis or terraform.\n→ \(program) TOOL\n"
                : "rv: name one tool at a time.\n→ \(program) \(DisplayedText.field(names[0]))\(off ? " off" : "")\n")
        }
        self.tool = tool
        self.off = off
    }
}

/// The words `rv protect` prints. One idea per line; the next command last.
enum ProtectText {
    static func protect(_ target: ProtectTarget, off: Bool = false) -> String {
        "\(CommandVocabulary.Command.protect.invocation) \(target.tool)\(off ? " off" : "")"
    }

    static func turnedOn(_ target: ProtectTarget) -> String {
        let rules = target.ruleCount == 1 ? "1 rule checks" : "\(target.ruleCount) rules check"
        return "  ✓ \(target.name) is protected. \(rules) its commands.\n"
            + "  → Undo: \(protect(target, off: true))\n"
    }

    static func alreadyOn(_ target: ProtectTarget) -> String {
        "  ✓ \(target.name) is already protected.\n"
    }

    static func turnedOff(_ target: ProtectTarget) -> String {
        "  ✓ \(target.name) is no longer protected.\n"
            + "  → Turn it back on: \(protect(target))\n"
    }

    static func alreadyOff(_ target: ProtectTarget) -> String {
        "  \(target.name) is not protected.\n"
    }

    static func required(_ target: ProtectTarget) -> String {
        "rv: \(target.name) stays protected: your organization's policy requires it.\n"
    }

    static func nearest(typed: String, target: ProtectTarget, off: Bool) -> String {
        "rv: no tool is named \(DisplayedText.field(typed)). Did you mean \(target.name)?\n"
            + "→ \(protect(target, off: off))\n"
    }

    static func unknown(typed: String) -> String {
        "rv: no tool is named \(DisplayedText.field(typed)).\n→ \(CommandVocabulary.Command.packs.invocation) --all\n"
    }
}

/// The two changes, after the name resolved. Both check `[packs]` first.
enum ProtectFlow {
    /// Tightening: no owner check. Only ever adds the pack.
    static func turnOn(_ target: ProtectTarget) throws {
        let home = try CommandContext.requireHome(command: "protect")
        try preflightPackMutation(ids: [target.packID.rawValue])
        if try isOn(target, home: home) {
            CommandContext.writeStdout(ProtectText.alreadyOn(target))
            return
        }
        try applyTightening(ids: [target.packID.rawValue], home: home)
        CommandContext.writeStdout(ProtectText.turnedOn(target))
    }

    /// Loosening: the owner check first, every time.
    static func turnOff(_ target: ProtectTarget) async throws {
        let home = try CommandContext.requireHome(command: "protect")
        try preflightPackMutation(ids: [target.packID.rawValue])
        if ManagedGate.requiredPacks(home: home).contains(target.packID) {
            try CommandContext.fail(ProtectText.required(target))
        }
        guard try isOn(target, home: home) else {
            CommandContext.writeStdout(ProtectText.alreadyOff(target))
            return
        }
        guard let authorization = try await packsOffAuthorization("turn off \(target.name) protection (\(target.packID.rawValue))") else {
            return
        }
        try ConfigChangeAudit.$authorization.withValue(authorization) {
            try applyLoosening(ids: [target.packID.rawValue], home: home)
        }
        CommandContext.writeStdout(ProtectText.turnedOff(target))
    }

    private static func isOn(_ target: ProtectTarget, home: HomeDirectory) throws -> Bool {
        do {
            return try PacksFacade.effectiveIDs(home: home).contains(target.packID)
        } catch let error as PacksCommandError {
            try failPackMutation(error, home: home)
        }
    }

    private static func applyLoosening(ids: [String], home: HomeDirectory) throws {
        do {
            _ = try PacksFacade.disable(home: home, ids: ids)
        } catch let error as PacksCommandError where error != .configUnwritable {
            try failPackMutation(error, home: home)
        } catch let unrecorded as ConfigChangeUnrecorded {
            try ConfigChangeRefusal.fail(command: "protect", unrecorded)
        } catch {
            try CommandContext.fail("rv: \(PacksConfigStore.configURL(home: home).path) could not be written; nothing changed.\n")
        }
    }
}

/// Turns packs on with no owner check. `PacksFacade.enableTightening`
/// refuses any change that would leave a pack that was on off.
func applyTightening(ids: [String], home: HomeDirectory) throws {
    do {
        _ = try PacksFacade.enableTightening(home: home, ids: ids)
    } catch let error as PacksCommandError where error != .configUnwritable {
        try failPackMutation(error, home: home)
    } catch let unrecorded as ConfigChangeUnrecorded {
        try ConfigChangeRefusal.fail(command: "protect", unrecorded)
    } catch {
        try CommandContext.fail("rv: \(PacksConfigStore.configURL(home: home).path) could not be written; nothing changed.\n")
    }
}

/// The command that turns a pack on, for explain and `rv packs test`:
/// `rv protect redis` when the pack has a tool name, else its id.
enum ProtectTurnOn {
    static func command(_ packID: PackID) -> String {
        let tool = (try? ProtectTools.bundled())?.target(packID)?.tool ?? packID.rawValue
        return "\(CommandVocabulary.Command.protect.invocation) \(tool)"
    }
}
