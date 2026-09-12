import Foundation
import Testing
@testable import RVCLI

@Test func completions_listEveryParserCommand() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let names = RV.configuration.subcommands.compactMap { $0.configuration.commandName }
    let files = [
        root.appendingPathComponent("share/completions/rv.bash"),
        root.appendingPathComponent("share/completions/rv.zsh"),
        root.appendingPathComponent("share/completions/rv.fish"),
    ]
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for name in names {
            #expect(text.contains(name), "\(file.lastPathComponent) missing \(name)")
        }
    }
}
