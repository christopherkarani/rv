import Foundation
import Testing
@testable import RVCLI

@Test func completions_listEveryParserCommand() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let names = RV.configuration.subcommands.compactMap { $0.configuration.commandName }
        + CommandAlias.leadingWords
    let files = [
        root.appendingPathComponent("Resources/Completions/rv.bash"),
        root.appendingPathComponent("Resources/Completions/rv.zsh"),
        root.appendingPathComponent("Resources/Completions/rv.fish"),
    ]
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for name in names {
            #expect(text.contains(name), "\(file.lastPathComponent) missing \(name)")
        }
    }
}

@Test func completions_offerPolicyCeilingSubcommands() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/Completions", isDirectory: true)
    let names = PolicyCeilingCommand.configuration.subcommands.map { $0.configuration.commandName ?? "" }
    #expect(names == ["show", "set"])
    let bash = try String(contentsOf: root.appendingPathComponent("rv.bash"), encoding: .utf8)
    #expect(bash.contains("compgen -W \"show set\""))
    let zsh = try String(contentsOf: root.appendingPathComponent("rv.zsh"), encoding: .utf8)
    #expect(zsh.contains("'show:Print ceiling.toml' 'set:Replace ceiling.toml'"))
    let fish = try String(contentsOf: root.appendingPathComponent("rv.fish"), encoding: .utf8)
    for name in names {
        #expect(fish.contains("__fish_seen_subcommand_from ceiling\" -a \"\(name)\""))
    }
    // After `ceiling`, fish offers only its subcommands, not policy's.
    #expect(fish.contains("-n \"__fish_seen_subcommand_from policy\" -a") == false)
}
