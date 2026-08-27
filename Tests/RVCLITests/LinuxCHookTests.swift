#if os(Linux)
import Foundation
import Testing
@testable import RVCLI

@Suite(.serialized)
struct LinuxCHookTests {
    @Test func cHookClangAndMissReplayDeniesResetHard() throws {
        let root = repoRootURL()
        let script = root.appendingPathComponent("tools/c-hook-proof.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))

        let isolationHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-c-hook-linux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: isolationHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolationHome) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        process.environment = [
            "HOME": isolationHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "TERM": "dumb",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "linux c-hook-proof failed:\n\(err)\n\(out)")
        #expect(out.contains("linux-clang ok"))
        #expect(out.contains("linux-last_resort ok"))
        #expect(out.contains("linux-miss_replay ok"))
        #expect(out.contains("linux-c-hook-proof ok"))
    }

    @Test func missReplaySwiftCliDeniesResetHard() async throws {
        let hook = try compileCHook()
        let cli = try #require(findSwiftRVExecutable(), "Swift rv product must be on the Linux graph")
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-c-miss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probe) }

        let rv = probe.appendingPathComponent("rv")
        try FileManager.default.copyItem(at: hook, to: rv)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rv.path)
        try writeExecutable(
            probe.appendingPathComponent("rv-cli"),
            contents: """
            #!/bin/sh
            exec "\(cli.path)" "$@"
            """
        )

        let fixture = repoRootURL()
            .appendingPathComponent("Tests/RVHooksTests/Fixtures/grok/deny-git-reset-hard.json")
        let home = probe.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = rv
        process.arguments = ["hook", "--host", "grok"]
        process.currentDirectoryURL = probe
        process.environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "TERM": "dumb",
        ]
        process.standardInput = FileHandle(forReadingAtPath: fixture.path)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(out.contains("\"decision\":\"deny\""))
        #expect(out.contains("RV · Blocked. Destroys uncommitted changes."))
        #expect(out.contains("git reset --hard") == false)
        #expect(out.contains("Terminal") == false)
        #expect(out.contains("allow-once") == false)
        #expect(out.contains("\"decision\":\"allow\"") == false)
    }
}

private func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func compileCHook() throws -> URL {
    let root = repoRootURL()
    let src = root.appendingPathComponent("Sources/rv-c")
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-c-built-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let dest = out.appendingPathComponent("rv")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    process.arguments = [
        "-Os", "-std=c11", "-Wall",
        "-I", src.path,
        "-o", dest.path,
        src.appendingPathComponent("json_escape.c").path,
        src.appendingPathComponent("json_reply.c").path,
        src.appendingPathComponent("rv.c").path,
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: dest.path) else {
        struct ClangFailed: Error {}
        throw ClangFailed()
    }
    return dest
}

private func writeExecutable(_ url: URL, contents: String) throws {
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func findSwiftRVExecutable() -> URL? {
    if let override = ProcessInfo.processInfo.environment["RV_SWIFT_RV"] {
        let url = URL(fileURLWithPath: override)
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
    }
    let runner = URL(fileURLWithPath: CommandLine.arguments[0])
    var dir = runner.deletingLastPathComponent()
    for _ in 0..<6 {
        let candidate = dir.appendingPathComponent("rv")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        dir = dir.deletingLastPathComponent()
    }
    let root = repoRootURL()
    let build = root.appendingPathComponent(".build")
    let names = [
        "debug/rv",
        "x86_64-unknown-linux-gnu/debug/rv",
        "aarch64-unknown-linux-gnu/debug/rv",
    ]
    for name in names {
        let candidate = build.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}
#endif
