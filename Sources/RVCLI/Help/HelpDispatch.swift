#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import Foundation
import RVDomain
import RVPresentation
import RVTheme
import RVTUI

/// Help surfaces reachable via `rv`, `rv help …`, or `<cmd> --help`.
public enum HelpTopic: Equatable, Sendable, CaseIterable {
    case root
    case help
    case test
    case `try`
    case explain
    case service
    case serviceStatus
    case serviceRestart
    case hook
    case setup
    case initialize
    case uninstall
    case doctor
    case allowOnce
    case packs
    case scan
    case policy
    case allowlist
    case safety
    case blocks
    case log
    case host
    case audit
    case secrets
    case mcp
    case managed
    case report
    case run
    case opencode
    case workspace
    case `operator`
    case egress
    case login
}

/// Intercepts help argv before ArgumentParser so passthrough commands still
/// get help, and every command gets rv's page rather than ArgumentParser's.
///
/// Whether a `--help` is rv's is read from the parser's own grammar
/// (`CommandGrammar`), so a new flag or positional needs no edit here.
public enum HelpDispatch {
    /// When non-`nil`, the process should print that page and exit 0.
    public static func topic(arguments: [String]) -> HelpTopic? {
        if arguments.isEmpty { return .root }

        let help = CommandVocabulary.Command.help.rawValue
        if arguments[0] == help {
            let path = arguments.dropFirst().filter { isHelpFlag($0) == false }
            if path.isEmpty { return .root }
            if path == [help] { return .help }
            return page(before: path[...]) ?? .root
        }

        guard let index = arguments.firstIndex(where: isHelpFlag) else { return nil }
        return page(before: arguments[..<index])
    }

    public static func text(_ topic: HelpTopic, palette: Palette) -> String {
        PrettyWriter.join(HelpRenderer().render(HelpCatalog.page(topic), palette: palette))
    }

    /// Renders help for the live TTY/color probe. Returns `true` when handled.
    public static func tryEmit(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdoutIsTTY: Bool? = nil
    ) -> Bool {
        guard let topic = topic(arguments: arguments) else { return false }
        let ttyOut = stdoutIsTTY ?? CLIProcess.stdoutIsTTY()
        let probe = ThemeProbeFactory.make(
            jsonFlag: false,
            robotFlag: false,
            plainFlag: false,
            noColorFlag: false,
            stdinIsTTY: false,
            stdoutIsTTY: ttyOut,
            environment: CLIProcess.context?.environment ?? environment
        )
        let ctx = CommandContext(
            command: "help",
            probe: probe,
            requested: .automatic,
            explicitRobot: false
        )
        let palette: Palette
        switch ctx.appearance {
        case .robot:
            palette = colorOffPalette
        case .pretty(let painted):
            palette = painted
        }
        CommandContext.writeStdout(text(topic, palette: palette))
        return true
    }

    /// The page a help flag after `tokens` asks for, walking the parser's
    /// grammar: subcommand names descend, and a command's own options and
    /// flags (with their values) are skipped. `nil` when the help flag is
    /// not rv's: it follows `--`, an option still waiting for its value, or
    /// input a passthrough argument captures (a positional or an unknown
    /// option on a command like `rv run`). Anywhere else an unknown option
    /// or an extra positional still gets the page: ArgumentParser would
    /// answer it with its own help. Without a grammar (`CommandGrammar.rv`
    /// is `nil`) it is always `nil`: ArgumentParser answers on its own.
    static func page(
        before tokens: ArraySlice<String>, grammar: CommandGrammar? = CommandGrammar.rv
    ) -> HelpTopic? {
        guard var node = grammar?.command else { return nil }
        var command: ParsableCommand.Type = RV.self
        var page = HelpTopic.root
        var rest = tokens
        while let token = rest.popFirst() {
            if token == "--" { return nil }
            if let child = node.subcommand(named: token),
               let childCommand = command.configuration.subcommands.first(where: { $0._commandName == child.commandName })
            {
                node = child
                command = childCommand
                page = HelpTopic.owning(command) ?? page
                continue
            }
            if token.hasPrefix("-"), let argument = node.argument(spelled: token) {
                if argument.kind == .option, token.contains("=") == false, rest.popFirst() == nil {
                    return nil
                }
                continue
            }
            if node.capturesPassthrough { return nil }
        }
        return page
    }

    private static func isHelpFlag(_ token: String) -> Bool {
        token == "-h" || token == "--help"
    }
}

extension HelpTopic {
    /// The commands whose `--help` and `rv help …` show this page. A
    /// command not listed shows its nearest listed parent's page.
    var commands: [ParsableCommand.Type] {
        switch self {
        case .root: [RV.self]
        case .help: []
        case .test: [Test.self]
        case .`try`: [Try.self]
        case .explain: [Explain.self]
        case .service: [Service.self]
        case .serviceStatus: [Status.self]
        case .serviceRestart: [Restart.self, Start.self]
        case .hook: [Hook.self]
        case .setup: [Setup.self]
        case .initialize: [Init.self]
        case .uninstall: [Uninstall.self]
        case .doctor: [Doctor.self]
        case .allowOnce: [AllowOnceCommand.self]
        case .packs: [Packs.self]
        case .scan: [Scan.self]
        case .policy: [Policy.self]
        case .allowlist: [AllowlistCommand.self]
        case .safety: [Safety.self]
        case .blocks: [Blocks.self]
        case .log: [Log.self]
        case .host: [HostCommand.self]
        case .audit: [Audit.self]
        case .secrets: [Secrets.self]
        case .mcp: [MCP.self]
        case .managed: [Managed.self]
        case .report: [ReportCommand.self]
        case .run: [Run.self]
        case .opencode: [OpenCode.self]
        case .workspace: [Workspace.self]
        case .`operator`: [Operator.self]
        case .egress: [Egress.self]
        case .login: [Login.self]
        }
    }

    /// The page `command` owns, if it has one of its own.
    static func owning(_ command: ParsableCommand.Type) -> HelpTopic? {
        allCases.first { $0.commands.contains { $0 == command } }
    }
}
