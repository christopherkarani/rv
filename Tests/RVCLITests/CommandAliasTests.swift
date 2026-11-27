import ArgumentParser
import Foundation
import RVDomain
import RVPolicy
import Testing
@testable import RVCLI

/// Q1's new names run their old spelling: the same parse, and from the
/// built `rv`, the same stdout, stderr and exit code byte for byte.
@Suite("New names are aliases of the old ones")
struct CommandAliasTests {
    @Test("each alias rewrites to the spelling it runs")
    func rewrites() {
        #expect(CommandAlias.expanded(["why", "git reset --hard"]) == ["explain", "git reset --hard"])
        #expect(CommandAlias.expanded(["why", "--json", "rm -rf ~"]) == ["explain", "--json", "rm -rf ~"])
        #expect(CommandAlias.expanded(["unlock", "a1b2c3"]) == ["allow-once", "a1b2c3"])
        #expect(CommandAlias.expanded(["unlock", "list"]) == ["allow-once", "list"])
        #expect(CommandAlias.expanded(["guard", "claude"]) == ["host", "mode", "claude", "block"])
        #expect(CommandAlias.expanded(["guard", "--json", "claude"]) == ["host", "mode", "--json", "claude", "block"])
        #expect(CommandAlias.expanded(["watch", "claude", "--json"]) == ["host", "mode", "claude", "observe", "--json"])
        #expect(CommandAlias.expanded(["watch", "--", "claude"]) == ["host", "mode", "--", "claude", "observe"])
        #expect(CommandAlias.expanded(["secrets", "add", "GH_TOKEN", "--environment"]) == ["secrets", "set", "GH_TOKEN", "--environment"])
        // Help pages: `rv <alias> --help` and `rv help <alias>`.
        #expect(CommandAlias.expanded(["guard", "--help"]) == ["host", "mode", "--help"])
        #expect(CommandAlias.expanded(["help", "why"]) == ["help", "explain"])
        #expect(CommandAlias.expanded(["help", "guard"]) == ["help", "host", "mode"])
        #expect(CommandAlias.expanded(["help", "secrets", "add"]) == ["help", "secrets", "set"])
    }

    @Test("other arguments are left alone")
    func leavesOthersAlone() {
        for argv in [[], ["explain", "why"], ["secrets", "list"], ["test", "guard"], ["host", "mode", "claude", "observe"], ["--version"]] {
            #expect(CommandAlias.expanded(argv) == argv)
        }
    }

    @Test("an alias without its host is refused with the fix, exit 64")
    func missingHost() throws {
        #expect(CommandAlias.expanded(["guard"]) == ["guard"])
        #expect(CommandAlias.expanded(["watch", "--json"]) == ["watch", "--json"])
        let message = try #require(UnknownCommand.message(arguments: ["guard"]))
        #expect(message == "rv: rv guard needs an agent, as in rv guard claude. rv host lists them.\n")
        #expect(UnknownCommand.message(arguments: ["watch", "--json"])?.hasPrefix("rv: rv watch needs an agent") == true)
    }

    @Test("new names are known; a typo of one is corrected")
    func typoCheckKnowsThem() {
        for word in ["why", "unlock", "guard", "watch"] {
            #expect(UnknownCommand.known.contains(word))
        }
        #expect(UnknownCommand.message(arguments: ["unlcok"])?.contains("Did you mean 'rv unlock'?") == true)
    }

    @Test("guard and watch set HostMode's own words")
    func modeWords() {
        #expect(CommandVocabulary.Alias.guard.runs.last == HostMode.block.rawValue)
        #expect(CommandVocabulary.Alias.watch.runs.last == HostMode.observe.rawValue)
    }

    @Test("every alias parses as the command it names", arguments: CommandVocabulary.Alias.allCases)
    func parsesAsTarget(_ alias: CommandVocabulary.Alias) throws {
        let sample = alias.runs.contains(CommandVocabulary.Alias.hostSlot) ? ["claude"] : []
        let new = try RV.parseAsRoot(CommandAlias.expanded(alias.words + sample))
        let old = try RV.parseAsRoot(alias.runs.map { $0 == CommandVocabulary.Alias.hostSlot ? "claude" : $0 })
        #expect(type(of: new) == type(of: old))
    }

    /// Old spelling, new spelling: run both from the built `rv` in the same
    /// empty home, which is wiped between runs.
    static let matrix: [(old: [String], new: [String])] = [
        (["explain", "git reset --hard"], ["why", "git reset --hard"]),
        (["explain", "--json", "git reset --hard"], ["why", "--json", "git reset --hard"]),
        (["explain", "git status"], ["why", "git status"]),
        (["explain"], ["why"]),
        (["explain", "--help"], ["why", "--help"]),
        (["help", "explain"], ["help", "why"]),
        (["allow-once", "a1b2c3"], ["unlock", "a1b2c3"]),
        (["allow-once", "list", "--json"], ["unlock", "list", "--json"]),
        (["allow-once", "--help"], ["unlock", "--help"]),
        (["host", "mode", "claude", "block", "--json"], ["guard", "claude", "--json"]),
        (["host", "mode", "claude", "observe"], ["watch", "claude"]),
        (["host", "mode", "nope", "block"], ["guard", "nope"]),
        (["host", "mode", "--help"], ["guard", "--help"]),
        (["help", "host", "mode"], ["help", "watch"]),
        (["secrets", "set"], ["secrets", "add"]),
        (["secrets", "set", "--help"], ["secrets", "add", "--help"]),
    ]

    @Test("old and new spellings print the same bytes and exit the same")
    func aliasMatrix() throws {
        let binary = try #require(builtRV(), "build rv first: swift build --build-tests")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-alias-matrix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for row in Self.matrix {
            let old = try run(binary, row.old, home: home)
            let new = try run(binary, row.new, home: home)
            #expect(new.status == old.status, "rv \(row.new.joined(separator: " ")): exit \(new.status), not \(old.status)")
            #expect(new.stdout == old.stdout, "rv \(row.new.joined(separator: " ")): stdout differs")
            #expect(new.stderr == old.stderr, "rv \(row.new.joined(separator: " ")): stderr differs")
        }
    }

    private func builtRV() -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            ".build/debug/rv",
            ".build/arm64-apple-macosx/debug/rv",
            ".build/x86_64-unknown-linux-gnu/debug/rv",
            ".build/aarch64-unknown-linux-gnu/debug/rv",
        ].map { root.appendingPathComponent($0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func run(_ binary: URL, _ arguments: [String], home: URL) throws -> (status: Int32, stdout: String, stderr: String) {
        try? FileManager.default.removeItem(at: home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "dumb"]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // A row that waits on a terminal or rvd must fail, not hang.
        let watchdog = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}
