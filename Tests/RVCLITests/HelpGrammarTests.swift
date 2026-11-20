import ArgumentParser
import Foundation
import Testing
@testable import RVCLI

/// Help pages and help dispatch agree with the real parser: what help
/// advertises parses, what the parser accepts is advertised, and `--help`
/// after anything the parser accepts is rv's own page, never
/// ArgumentParser's.
@Suite("Help follows the parser")
struct HelpGrammarTests {
    @Test("every usage row on every help page parses with the real parser")
    func usageRowsParse() {
        var failures: [String] = []
        for topic in HelpTopic.allCases {
            for row in HelpCatalog.page(topic).sections.flatMap(\.rows) where row.name.hasPrefix("rv ") {
                for mode in UsageRow.Mode.allCases {
                    let argv = UsageRow.argv(row.name, mode: mode)
                    do {
                        _ = try RV.parseAsRoot(argv)
                    } catch {
                        failures.append("\(row.name)\n    \(argv.joined(separator: " ")): \(RV.message(for: error))")
                    }
                }
            }
        }
        #expect(failures.isEmpty, "usage rows the parser refuses:\n\(failures.joined(separator: "\n"))")
    }

    @Test("a command's usage rows name every option and flag it has")
    func usageRowsNameEveryOption() throws {
        let grammar = try #require(CommandGrammar.rv)
        // Output format flags are on most commands; a row may leave them out.
        let exempt = Set(Self.spellings(in: FormatFlags.usageString()) + ["--help", "--version"])
        var declared = 0
        for (command, node) in Self.pairs(RV.self, grammar.command) {
            guard let usage = command as? any CommandUsage.Type else { continue }
            declared += 1
            let written = Set(usage.usage.flatMap { Self.spellings(in: $0.name) })
            let known = node.walk().flatMap { $0.command.arguments ?? [] }
                .filter { $0.kind != .positional }
                .compactMap(\.spellings.first)
            for spelling in Set(known).subtracting(exempt) {
                #expect(written.contains(spelling), "`\(usage.usage.first?.name ?? "")`: usage omits \(spelling)")
            }
        }
        #expect(declared > 0)
    }

    @Test("every Flags row names an option its page's commands have")
    func flagRowsAreRealOptions() throws {
        let grammar = try #require(CommandGrammar.rv)
        for topic in HelpTopic.allCases {
            let nodes = Self.pairs(RV.self, grammar.command)
                .filter { pair in topic.commands.contains { $0 == pair.command } }
                .flatMap { $0.node.walk().map(\.command) }
            let known = Set(nodes.flatMap { $0.arguments ?? [] }.flatMap(\.spellings))
            let rows = HelpCatalog.page(topic).sections.filter { $0.heading == "Flags" }.flatMap(\.rows)
            for row in rows {
                for spelling in Self.spellings(in: row.name) {
                    #expect(known.contains(spelling), "\(topic) help lists \(spelling), which its commands do not have")
                }
            }
        }
    }

    @Test("every command on a usage-row page declares its rows")
    func usagePagesListEveryCommand() {
        // `UsageRows.under` skips a command with neither rows nor
        // subcommands, so a new subcommand without `usage` would drop off
        // its page without this.
        var parents = 0
        for command in Self.commands(RV.self) {
            guard command.configuration.subcommands.contains(where: { $0 is any CommandUsage.Type }) else { continue }
            parents += 1
            let usage = HelpTopic.owning(command).flatMap { topic in
                HelpCatalog.page(topic).sections.first { $0.heading == "Usage" }?.rows
            }
            #expect(usage == UsageRows.under(command), "\(command._commandName)'s page does not list UsageRows.under")
            for missing in Self.withoutUsage(under: command) {
                Issue.record("`\(command._commandName) \(missing._commandName)` has no usage rows, so its page leaves it out")
            }
        }
        #expect(parents >= 2)
    }

    @Test("--help after any real flag, option or positional is the command's rv page")
    func helpAfterEveryArgument() throws {
        let grammar = try #require(CommandGrammar.rv)
        for (path, command) in grammar.command.walk() where path.isEmpty == false {
            let page = HelpDispatch.topic(arguments: path + ["--help"])
            #expect(page != nil, "`rv \(path.joined(separator: " ")) --help` is not an rv page")
            #expect(HelpDispatch.topic(arguments: ["help"] + path) == page, "`rv help \(path.joined(separator: " "))`")
            let probes = command.helpProbes(path: path)
            for argv in probes.own {
                #expect(HelpDispatch.topic(arguments: argv) == page, "`rv \(argv.joined(separator: " "))`")
            }
            // Dispatch walks the same grammar these probes come from, so the
            // parser itself is asked too.
            for argv in probes.passthrough {
                #expect(HelpDispatch.topic(arguments: argv) == nil, "`rv \(argv.joined(separator: " "))` stole the command's --help")
                if Self.parserDiffers[argv] == nil {
                    #expect(Self.parserAsksForHelp(argv) == false, "`rv \(argv.joined(separator: " "))`: the parser answers this --help, not the captured command")
                }
            }
            // Before a passthrough capture starts, the parser reads `--help`
            // as the first captured word and never asks for help: that is
            // why rv answers it first. Elsewhere both must ask for help.
            guard command.capturesPassthrough == false else { continue }
            for argv in [path + ["--help"]] + probes.own where Self.parserDiffers[argv] == nil {
                #expect(Self.parserAsksForHelp(argv), "`rv \(argv.joined(separator: " "))` gets rv's page, but the parser does not ask for help")
            }
        }
    }

    @Test("each known difference from the parser's help is still one")
    func knownParserDifferences() {
        for (argv, _) in Self.parserDiffers {
            let rvPage = HelpDispatch.topic(arguments: argv) != nil
            #expect(Self.parserAsksForHelp(argv) != rvPage, "`rv \(argv.joined(separator: " "))` now agrees with the parser; drop it from parserDiffers")
        }
    }

    @Test("a grammar rv cannot read leaves --help to ArgumentParser")
    func unreadableGrammarFallsBack() {
        #expect(CommandGrammar.decode(Data("{}".utf8)) == nil)
        #expect(CommandGrammar.decode(Data("not json".utf8)) == nil)
        #expect(HelpDispatch.page(before: ["workspace", "run", "--rows", "5"], grammar: nil) == nil)
        #expect(HelpDispatch.page(before: [], grammar: nil) == nil)
        // Fields rv does not read may change or go away.
        let minimal = #"{"command":{"commandName":"rv","subcommands":[{"commandName":"x","arguments":[{"kind":"flag","names":[{"kind":"long","name":"y"}],"parsingStrategy":"default"}]}]}}"#
        let grammar = CommandGrammar.decode(Data(minimal.utf8))
        #expect(grammar?.command.subcommand(named: "x")?.argument(spelled: "--y")?.kind == .flag)
    }

    /// Where rv's help dispatch and the parser's own help knowingly differ,
    /// besides passthrough commands. Each one is harmless: nothing runs.
    static let parserDiffers: [[String]: String] = [
        // `-n` is `audit tail`'s, reached through the default subcommand;
        // the parser reports its missing value, rv shows the audit page.
        ["audit", "-n", "--help"]: "option of the default subcommand",
        // The `--help` is the captured command's, so rv leaves it alone; the
        // parser answers it with help only because the required
        // `--expected-content-digest-sha256` is missing.
        ["workspace", "custom", "1", "--help"]: "missing required option",
    ]

    /// Whether ArgumentParser answers `argv` with its own help: parsing
    /// gives its built-in help command, or stops with a help message.
    static func parserAsksForHelp(_ argv: [String]) -> Bool {
        do {
            let command = try RV.parseAsRoot(argv)
            return String(describing: type(of: command)) == "HelpCommand"
        } catch {
            return RV.exitCode(for: error) == .success && RV.fullMessage(for: error).contains("USAGE:")
        }
    }

    /// Every command type under `command`, `command` first.
    static func commands(_ command: ParsableCommand.Type) -> [ParsableCommand.Type] {
        [command] + command.configuration.subcommands.flatMap { commands($0) }
    }

    /// The commands `UsageRows.under(parent)` reaches that have no rows.
    static func withoutUsage(under parent: ParsableCommand.Type) -> [ParsableCommand.Type] {
        parent.configuration.subcommands.flatMap { command -> [ParsableCommand.Type] in
            if let declared = command as? any CommandUsage.Type { return declared.usage.isEmpty ? [command] : [] }
            let subcommands = command.configuration.subcommands
            return subcommands.isEmpty ? [command] : withoutUsage(under: command)
        }
    }

    /// `--name` and `-n` words in usage or flag text.
    static func spellings(in text: String) -> [String] {
        text.split(whereSeparator: { " []|/,".contains($0) })
            .map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? String($0) }
            .filter { $0.hasPrefix("-") && $0 != "--" && $0.count > 1 && $0 != "-" }
    }

    /// Each command type with its grammar node, `RV` first.
    static func pairs(
        _ command: ParsableCommand.Type, _ node: CommandGrammar.Command
    ) -> [(command: ParsableCommand.Type, node: CommandGrammar.Command)] {
        [(command, node)] + command.configuration.subcommands.flatMap { sub in
            node.subcommand(named: sub._commandName).map { pairs(sub, $0) } ?? []
        }
    }
}
