import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

@Suite struct ShellWordTests {
    @Test func safePathsStayByteIdentical() {
        #expect(ShellWord.quote("/Users/me/.local/bin/rv") == "/Users/me/.local/bin/rv")
    }

    @Test func spacesAndQuotesAreSingleQuoted() {
        #expect(ShellWord.quote("/Users/a b/rv") == "'/Users/a b/rv'")
        #expect(ShellWord.quote("/Users/o'n/rv") == #"'/Users/o'\''n/rv'"#)
    }

    @Test func leadingWordRoundTripsQuote() throws {
        for value in ["/plain/rv", "/Users/a b/rv", "/Users/o'n/x y", "/a$b/`c`"] {
            let parsed = try #require(ShellWord.leadingWord(Substring(ShellWord.quote(value) + " tail")))
            #expect(parsed.word == value)
            #expect(parsed.rest == " tail")
        }
        #expect(ShellWord.leadingWord("'unterminated") == nil)
    }
}

@Suite struct HookCommandQuotingTests {
    private let rv = "/Users/a b/.local/bin/rv"
    private let interpreter = "/Users/a b/py/bin/python3"
    private let adapter = "/Users/a b/.claude/hooks/rv-guard.py"

    @Test func claudeCommandQuotesEveryPathAndParsesBack() {
        let command = SettingsMergePolicy.hookCommand(rvPath: rv, interpreter: interpreter, adapterPath: adapter)
        #expect(command
            == "RV_BINARY='/Users/a b/.local/bin/rv' '/Users/a b/py/bin/python3' -I -S '/Users/a b/.claude/hooks/rv-guard.py'")
        #expect(ClaudeSettingsMerge.bakedRvPath(in: command) == rv)
        #expect(SettingsMergePolicy.adapterPath(in: command) == adapter)
        #expect(SettingsMergePolicy.bakedInterpreter(in: command) == interpreter)
    }

    @Test func codexAndCursorBakeTheInterpreterAndQuoteTheAdapter() {
        #expect(CodexHooksMerge.hookCommand(interpreter: "/usr/bin/python3", adapterPath: "/h x/.codex/hooks/rv-guard.py")
            == "/usr/bin/python3 -I -S '/h x/.codex/hooks/rv-guard.py'")
        #expect(CursorHooksMerge.hookCommand(interpreter: "/usr/bin/python3", adapterPath: "/h x/.cursor/hooks/rv-guard.py")
            == "/usr/bin/python3 -I -S '/h x/.cursor/hooks/rv-guard.py'")
        #expect(CodexHooksMerge.adapterPath(in: "/usr/bin/python3 -I -S '/h x/.codex/hooks/rv-guard.py'")
            == "/h x/.codex/hooks/rv-guard.py")
        #expect(CodexHooksMerge.adapterPath(in: "python3 '/h x/.codex/hooks/rv-guard.py'")
            == "/h x/.codex/hooks/rv-guard.py")
    }

    @Test func cursorKeepsFailClosed() {
        let entry = CursorHooksMerge.hookEntry(interpreter: "/usr/bin/python3", adapterPath: "/h/.cursor/hooks/rv-guard.py")
        #expect(entry.failClosed == true)
    }

    @Test(arguments: [
        "RV_BINARY=/Users/a b/.local/bin/rv python3 /Users/a b/.claude/hooks/rv-guard.py",
        "RV_BINARY='/Users/a b/.local/bin/rv' python3 '/Users/a b/.claude/hooks/rv-guard.py'",
    ])
    func earlierPathCommandIsOursAndOutdated(_ legacy: String) {
        let hook = claudeHook(legacy)
        let descriptor = ClaudeSettingsMerge.mergeDescriptor
        #expect(SettingsMergePolicy.matchesCurrentCommand(hook, descriptor: descriptor))
        #expect(SettingsMergePolicy.matchesCurrentHook(hook, descriptor: descriptor) == false)
        #expect(ClaudeSettingsMerge.bakedRvPath(in: legacy) == rv)
        #expect(SettingsMergePolicy.bakedInterpreter(in: legacy) == nil)
    }

    @Test(arguments: [
        "RV_BINARY=/r /usr/bin/python3 /c/.claude/hooks/rv-guard.py",
        "RV_BINARY=/r python3 -I -S /c/.claude/hooks/rv-guard.py",
        "RV_BINARY=/r /usr/bin/python3 -I /c/.claude/hooks/rv-guard.py",
        "RV_BINARY=/r /usr/bin/python3 -S -I /c/.claude/hooks/rv-guard.py",
    ])
    func otherInterpreterFormsAreNotOurs(_ command: String) {
        let hook = claudeHook(command)
        #expect(SettingsMergePolicy.matchesCurrentCommand(hook, descriptor: ClaudeSettingsMerge.mergeDescriptor) == false)
        #expect(CodexHooksMerge.isCurrentCommand(
            String(command.dropFirst("RV_BINARY=/r ".count)), adapterPath: "/c/.claude/hooks/rv-guard.py") == false)
    }

    @Test func setupInAHomeWithASpaceWritesARunnableClaudeHook() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv quoted \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(root.appendingPathComponent("rvd"))
        let layout = OwnedPaths(home: try #require(HomeDirectory(validating: root.path)))
        try FileManager.default.createDirectory(atPath: layout.claudeDirectory, withIntermediateDirectories: true)
        let rvPath = root.path + "/.local/bin/rv"
        let outcome = SetupRun.setup(env(home: root, launchctl: RecordingLaunchctl(), rvPath: rvPath))
        #expect(outcome.exitCode == 0, "\(outcome.stderr)")
        let settings = try String(contentsOfFile: layout.claudeSettings, encoding: .utf8)
        #expect(settings.contains(
            "RV_BINARY='\(rvPath)' /usr/bin/python3 -I -S '\(root.path)/.claude/hooks/rv-guard.py'"))
    }

    private func claudeHook(_ command: String) -> JSONValue {
        .object([
            "type": .string("command"),
            "command": .string(command),
            "timeout": .number(Double(ClaudeSettingsMerge.mergeDescriptor.timeout)),
        ])
    }
}
