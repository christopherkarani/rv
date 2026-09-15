import Foundation
#if canImport(Darwin)
import Darwin
#endif
import Testing
import RVDomain
import RVHooks
import RVTheme
@testable import RVCLI

@Test func hookDispatch_matchesHookButNotHelpOrOtherCommands() {
    #expect(HookDispatch.matches(["hook"]))
    #expect(HookDispatch.matches(["hook", "--help"]) == false)
    #expect(HookDispatch.matches(["test"]) == false)
}

@Test func hookDispatch_matchesSkipsHelpDispatchPaths() {
    #expect(HookDispatch.matches(["hook", "-h"]) == false)
    #expect(HookDispatch.matches(["hook", "--host", "pi", "--help"]) == false)
    #expect(HookDispatch.matches(["hook", "--host=grok", "--help"]) == false)
    #expect(HookDispatch.matches(["help", "hook"]) == false)
    #expect(HelpDispatch.topic(arguments: ["hook", "--help"]) == .hook)
}

@Test func hookDispatch_matchesHostOptions() {
    #expect(HookDispatch.matches(["hook", "--host", "grok"]))
    #expect(HookDispatch.matches(["hook", "--host=pi"]))
    #expect(HookDispatch.matches(["hook", "--host", "opencode"]))
    #expect(HookDispatch.matches(["hook", "--host", "claude"]))
    #expect(HookDispatch.matches(["hook", "--host=claude"]))
    #expect(HookDispatch.matches(["hook", "--host", "openclaw"]))
    #expect(HookDispatch.matches(["hook", "--host=openclaw"]))
    #expect(HookDispatch.matches(["hook", "--host", "hermes"]))
    #expect(HookDispatch.matches(["hook", "--host=hermes"]))
    #expect(HookDispatch.matches(["hook", "--host", "codex"]))
    #expect(HookDispatch.matches(["hook", "--host=codex"]))
    #expect(HookDispatch.matches(["hook", "--host", "cursor"]))
    #expect(HookDispatch.matches(["hook", "--host=cursor"]))
}

@Test func hookDispatch_parsesHostTheSameAsHook() throws {
    #expect(try HookDispatch.parse([]).host == .grok)
    #expect(try HookDispatch.parse(["--host", "grok"]).host == .grok)
    #expect(try HookDispatch.parse(["--host=grok"]).host == .grok)
    #expect(try HookDispatch.parse(["--host", "pi"]).host == .pi)
    #expect(try HookDispatch.parse(["--host=opencode"]).host == .opencode)
    #expect(try HookDispatch.parse(["--host", "claude"]).host == .claude)
    #expect(try HookDispatch.parse(["--host=claude"]).host == .claude)
    #expect(try HookDispatch.parse(["--host", "openclaw"]).host == .openclaw)
    #expect(try HookDispatch.parse(["--host=openclaw"]).host == .openclaw)
    #expect(try HookDispatch.parse(["--host", "hermes"]).host == .hermes)
    #expect(try HookDispatch.parse(["--host=hermes"]).host == .hermes)
    #expect(try HookDispatch.parse(["--host", "codex"]).host == .codex)
    #expect(try HookDispatch.parse(["--host=codex"]).host == .codex)
    #expect(try HookDispatch.parse(["--host", "cursor"]).host == .cursor)
    #expect(try HookDispatch.parse(["--host=cursor"]).host == .cursor)
}

@Test func hookDispatch_invalidHost_doesNotEvaluate() async {
    let probe = DispatchEvaluateProbe()
    await #expect(throws: (any Error).self) {
        _ = try await HookDispatch.run(
            arguments: ["--host", "unknown"],
            stdin: grokBashStdin("git reset --hard"),
            evaluate: { command, _ in
                probe.record(command)
            }
        )
    }
    #expect(probe.commands.isEmpty)
}

@Test func hookDispatch_injectedEvaluate_deniesResetHard() async throws {
    let outcome = try await HookDispatch.run(
        arguments: ["--host", "grok"],
        stdin: grokBashStdin("git reset --hard"),
        evaluate: inProcessEvaluate
    )
    let json = try dispatchDenyJSON(outcome.stdout)
    #expect(json["decision"] as? String == "deny")
    #expect(json["reason"] as? String == hostDenyText(
        from: EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
                ),
                matched: nil
            )
        ),
        command: ShellCommand(rawValue: "git reset --hard")
    ))
    #expect(json["rule"] as? String == "core.git/reset-hard")
    #expect(outcome.exitCode == 0)
    #expect(outcome.stderr.isEmpty)
}

@Test func hookDispatch_injectedEvaluate_allowsStashDrop() async throws {
    let outcome = try await HookDispatch.run(
        arguments: [],
        stdin: grokBashStdin("git stash drop"),
        evaluate: inProcessEvaluate
    )
    #expect(outcome.stdout.isEmpty)
    #expect(outcome.exitCode == 0)
    #expect(outcome.stdout.contains("deny") == false)
    #expect(outcome.stderr.isEmpty)
}

@Test func hookDispatch_equalsHostForm_allowsStashDrop() async throws {
    let outcome = try await HookDispatch.run(
        arguments: ["--host=grok"],
        stdin: grokBashStdin("git stash drop"),
        evaluate: inProcessEvaluate
    )
    #expect(outcome.stdout.isEmpty)
    #expect(outcome.exitCode == 0)
}

@Test func hookDispatch_process_allowDenyAndHelp() async throws {
    let rv = try #require(
        builtRVExecutable(),
        "build --product rv to prove the process hook path"
    )
    try await withIsolatedEvaluateService {
        try await withDispatchTempHome { home in
        let allow = try runBuiltRV(
            rv,
            arguments: ["hook", "--host", "grok"],
            stdin: grokBashStdin("git stash drop"),
            home: home
        )
        #expect(allow.stdout.isEmpty)
        #expect(allow.status == 0)

        let deny = try runBuiltRV(
            rv,
            arguments: ["hook", "--host", "grok"],
            stdin: grokBashStdin("git reset --hard"),
            home: home
        )
        let json = try dispatchDenyJSON(deny.stdout)
        #expect(json["decision"] as? String == "deny")
        #expect(json["reason"] as? String == "RV · Blocked. Destroys uncommitted changes. Use 'git stash' first.")
        #expect((json["reason"] as? String)?.contains("git reset --hard") == false)
        #expect((json["reason"] as? String)?.contains("Terminal") == false)
        #expect((json["reason"] as? String)?.contains("allow-once") == false)
        #expect(deny.status == 0)

        let help = try runBuiltRV(
            rv,
            arguments: ["hook", "--help"],
            stdin: "",
            home: home
        )
        #expect(help.status == 0)
        #expect(help.stdout == HelpDispatch.text(.hook, palette: colorOffPalette))
        #expect(help.stdout.contains("OVERVIEW:") == false)
        #expect(help.stdout.contains("SUBCOMMANDS:") == false)
        #expect(help.stderr.contains("Error:") == false)
        }
    }
}

private final class DispatchEvaluateProbe: @unchecked Sendable {
    private(set) var commands: [String] = []

    func record(_ command: ShellCommand) -> EvaluationResult {
        commands.append(command.rawValue)
        return EvaluationResult(outcome: .plain)
    }
}

private func grokBashStdin(_ command: String) -> String {
    """
    {"hookEventName":"pre_tool_use","toolName":"Bash","toolInput":{"command":\(dispatchJSONFragment(command))}}
    """
}

private func dispatchJSONFragment(_ value: String) -> String {
    guard
        let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
        let text = String(data: data, encoding: .utf8)
    else {
        return "\"\""
    }
    return text
}

private func dispatchDenyJSON(_ stdout: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(stdout.utf8))
    return try #require(object as? [String: Any])
}

private func inProcessEvaluate(_ command: ShellCommand, cwd: WorkingDirectory?) async -> EvaluationResult {
    do {
        let client = try isolatedClient(transport: nil)
        return await client.evaluateResult(command: command, cwd: cwd)
    } catch {
        return EvaluationResult(outcome: .indeterminate(.corePacksUnavailable))
    }
}

private func withDispatchTempHome<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-hook-dispatch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

private func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func builtRVExecutable() -> URL? {
    let fm = FileManager.default
    let roots = [
        repoRootURL(),
        URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true),
    ]
    let relatives = [
        ".build/debug/rv",
        ".build/arm64-apple-macosx/debug/rv",
        ".build/x86_64-unknown-linux-gnu/debug/rv",
        ".build/aarch64-unknown-linux-gnu/debug/rv",
    ]
    for root in roots {
        for relative in relatives {
            let url = root.appendingPathComponent(relative)
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
    }
    return nil
}

private func runBuiltRV(
    _ executable: URL,
    arguments: [String],
    stdin: String,
    home: URL
) throws -> (stdout: String, stderr: String, status: Int32) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = [
        "HOME": home.path,
        "PATH": "/usr/bin:/bin",
        "TERM": "dumb",
    ]
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
    try stdinPipe.fileHandleForWriting.close()
    process.waitUntilExit()
    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (stdout, stderr, process.terminationStatus)
}

private let evaluateProofLockPath = "/tmp/swift-arch-c8hook21/c-hook-proof.lockdir"
private let evaluateProofAsideSuffix = ".rv-c-hook-proof-aside"
private let evaluateProofLabel = "dev.rv.evaluate"

/// Built `rv hook` uses the login Mach service. Park it so temp HOME evaluates in-process.
private func withIsolatedEvaluateService<T>(
    _ body: () async throws -> T
) async throws -> T {
#if os(macOS)
    try await withEvaluateProofLock {
        try await withParkedLiveEvaluateAgent(body)
    }
#else
    try await body()
#endif
}

#if os(macOS)
private struct EvaluateProofLockError: Error {}

private func withEvaluateProofLock<T>(
    _ body: () async throws -> T
) async throws -> T {
    mkdir("/tmp/swift-arch-c8hook21", mode_t(0o755))
    var acquired = false
    for _ in 1...360 {
        if mkdir(evaluateProofLockPath, mode_t(0o755)) == 0 {
            acquired = true
            break
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    guard acquired else {
        throw EvaluateProofLockError()
    }
    defer { rmdir(evaluateProofLockPath) }
    return try await body()
}

private func loginHomePath() -> String? {
    guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
        return nil
    }
    return String(cString: dir)
}

private func launchctl(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return 1
    }
}

private func evaluateServiceTarget() -> (domain: String, target: String) {
    let domain = "gui/\(getuid())"
    return (domain, "\(domain)/\(evaluateProofLabel)")
}

private func evaluateServiceIsLoaded(_ target: String) -> Bool {
    launchctl(["print", target]) == 0
}

private func bootoutEvaluateService(_ target: String) {
    _ = launchctl(["bootout", target])
    for _ in 1...25 {
        if evaluateServiceIsLoaded(target) == false {
            return
        }
        _ = launchctl(["bootout", target])
        usleep(200_000)
    }
}

private func withParkedLiveEvaluateAgent<T>(
    _ body: () async throws -> T
) async throws -> T {
    let fm = FileManager.default
    let names = evaluateServiceTarget()
    guard let login = loginHomePath() else {
        return try await body()
    }
    let live = URL(fileURLWithPath: login)
        .appendingPathComponent("Library/LaunchAgents/\(evaluateProofLabel).plist")
    let aside = URL(fileURLWithPath: live.path + evaluateProofAsideSuffix)
    let loaded = evaluateServiceIsLoaded(names.target)
    if fm.fileExists(atPath: live.path) == false && fm.fileExists(atPath: aside.path) {
        try fm.moveItem(at: aside, to: live)
    }
    if loaded && fm.fileExists(atPath: live.path) == false {
        throw EvaluateProofLockError()
    }
    var parked: URL?
    if fm.fileExists(atPath: live.path) {
        if fm.fileExists(atPath: aside.path) {
            try fm.removeItem(at: aside)
        }
        try fm.moveItem(at: live, to: aside)
        parked = aside
    }
    bootoutEvaluateService(names.target)
    defer {
        bootoutEvaluateService(names.target)
        if let parked {
            if fm.fileExists(atPath: live.path) == false, fm.fileExists(atPath: parked.path) {
                try? fm.moveItem(at: parked, to: live)
            }
            if loaded, fm.fileExists(atPath: live.path) {
                _ = launchctl(["bootstrap", names.domain, live.path])
            }
        }
    }
    return try await body()
}
#endif
