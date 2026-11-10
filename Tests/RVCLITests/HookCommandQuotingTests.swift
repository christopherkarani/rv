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
    private let adapter = "/Users/a b/.claude/hooks/rv-guard.py"

    @Test func claudeCommandQuotesBothPathsAndParsesBack() {
        let command = SettingsMergePolicy.hookCommand(rvPath: rv, adapterPath: adapter)
        #expect(command == "RV_BINARY='/Users/a b/.local/bin/rv' python3 '/Users/a b/.claude/hooks/rv-guard.py'")
        #expect(ClaudeSettingsMerge.bakedRvPath(in: command) == rv)
        #expect(SettingsMergePolicy.adapterPath(in: command) == adapter)
    }

    @Test func codexAndCursorQuoteTheAdapter() {
        #expect(CodexHooksMerge.hookCommand(adapterPath: "/h x/.codex/hooks/rv-guard.py")
            == "python3 '/h x/.codex/hooks/rv-guard.py'")
        #expect(CursorHooksMerge.hookCommand(adapterPath: "/h x/.cursor/hooks/rv-guard.py")
            == "python3 '/h x/.cursor/hooks/rv-guard.py'")
        #expect(CodexHooksMerge.adapterPath(in: "python3 '/h x/.codex/hooks/rv-guard.py'")
            == "/h x/.codex/hooks/rv-guard.py")
    }

    @Test func cursorKeepsFailClosed() {
        let entry = CursorHooksMerge.hookEntry(adapterPath: "/h/.cursor/hooks/rv-guard.py")
        #expect(entry.failClosed == true)
    }

    @Test func earlierUnquotedCommandIsOursAndOutdated() {
        let legacy = SettingsMergePolicy.unquotedHookCommand(rvPath: rv, adapterPath: adapter)
        let hook: JSONValue = .object([
            "type": .string("command"),
            "command": .string(legacy),
            "timeout": .number(Double(ClaudeSettingsMerge.mergeDescriptor.timeout)),
        ])
        let descriptor = ClaudeSettingsMerge.mergeDescriptor
        #expect(SettingsMergePolicy.matchesCurrentCommand(hook, descriptor: descriptor))
        #expect(SettingsMergePolicy.matchesCurrentHook(hook, descriptor: descriptor) == false)
        #expect(ClaudeSettingsMerge.bakedRvPath(in: legacy) == rv)
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
        #expect(settings.contains("RV_BINARY='\(rvPath)' python3 '\(root.path)/.claude/hooks/rv-guard.py'"))
    }
}
