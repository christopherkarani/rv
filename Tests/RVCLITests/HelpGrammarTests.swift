import ArgumentParser
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
            for argv in probes.passthrough {
                #expect(HelpDispatch.topic(arguments: argv) == nil, "`rv \(argv.joined(separator: " "))` stole the command's --help")
            }
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
