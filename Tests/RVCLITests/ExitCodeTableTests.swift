import ArgumentParser
import Foundation
import Testing
@testable import RVCLI

/// One exit-code table for every command (`ExitStatus`): 0 ok, 1 stopped
/// or a problem, 2 not found, 64 usage. Codes outside it are the kept
/// ones a caller depends on (`ExitStatus.kept`).
@Suite("Every command exits from one table")
struct ExitCodeTableTests {
    @Test("the table is 0, 1, 2 and 64")
    func table() {
        #expect(ExitStatus.allCases.map(\.rawValue) == [0, 1, 2, 64])
        #expect(ExitStatus.usage.rawValue == EX_USAGE)
    }

    /// A bad flag on any command is a usage error, 64, never ArgumentParser
    /// answering some other way. Commands that hand their arguments to
    /// another program (`rv run -- …`, `rv box`, `rv hook`) are left out:
    /// the flag belongs to that program.
    @Test("a bad flag on every command exits 64")
    func badFlagIsUsage() throws {
        let grammar = try #require(CommandGrammar.rv)
        var checked = 0
        for (path, command) in grammar.command.walk() where path.isEmpty == false && command.capturesPassthrough == false {
            let argv = path + ["--rv-no-such-flag"]
            do {
                _ = try RV.parseAsRoot(argv)
                Issue.record("rv \(argv.joined(separator: " ")) parsed")
            } catch {
                #expect(RV.exitCode(for: error).rawValue == ExitStatus.usage.rawValue, "rv \(argv.joined(separator: " "))")
            }
            checked += 1
        }
        #expect(checked > 50)
    }

    @Test("an unknown command and an alias with no agent exit 64 (main.swift)")
    func unknownCommandIsUsage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent("Sources/rv/main.swift"), encoding: .utf8)
        #expect(main.contains("exit(ExitStatus.usage.rawValue)"))
        #expect(UnknownCommand.message(arguments: ["stauts"]) != nil)
    }

    /// Every exit code written as a number or a sysexits name in the CLI's
    /// sources is in the table or kept. A new code fails here until it
    /// joins one of them.
    @Test("every exit code in the sources is in the table or kept")
    func sourcesUseTheTable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let allowed = Set(ExitStatus.allCases.map(\.rawValue)).union([EX_USAGE]).union(ExitStatus.kept.map(\.code))
        let named: [String: Int32] = [
            "EX_USAGE": EX_USAGE, "EX_DATAERR": EX_DATAERR, "EX_UNAVAILABLE": EX_UNAVAILABLE,
            "EX_SOFTWARE": EX_SOFTWARE, "EX_CANTCREAT": EX_CANTCREAT, "EX_IOERR": EX_IOERR,
            "EX_NOPERM": EX_NOPERM, "EX_CONFIG": EX_CONFIG, "EX_NOINPUT": EX_NOINPUT,
            "EX_NOUSER": EX_NOUSER, "EX_NOHOST": EX_NOHOST, "EX_OSERR": EX_OSERR,
            "EX_OSFILE": EX_OSFILE, "EX_TEMPFAIL": EX_TEMPFAIL, "EX_PROTOCOL": EX_PROTOCOL,
        ]
        let pattern = try NSRegularExpression(
            pattern: #"(?:exitCode: |ExitCode\(|exit\(|exitCode = )(\d+|EX_[A-Z]+)\b"#)
        var outside: [String] = []
        var seen = 0
        for directory in ["Sources/RVCLI", "Sources/rv"] {
            let walk = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil))
            for case let file as URL in walk where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                let range = NSRange(text.startIndex..., in: text)
                for match in pattern.matches(in: text, range: range) {
                    guard let token = Range(match.range(at: 1), in: text).map({ String(text[$0]) }) else { continue }
                    seen += 1
                    let code = Int32(token) ?? named[token]
                    if let code, allowed.contains(code) { continue }
                    outside.append("\(file.lastPathComponent): \(token)")
                }
            }
        }
        #expect(seen > 50)
        #expect(outside.isEmpty, "exit codes outside ExitStatus and ExitStatus.kept:\n\(outside.joined(separator: "\n"))")
    }
}
