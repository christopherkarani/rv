import ArgumentParser
import Foundation
import RVTheme
import Testing
@testable import RVCLI

@Suite("OpenCode command")
struct OpenCodeCommandTests {
    @Test func registeredAndDocumented() {
        #expect(RV.configuration.subcommands.contains { $0.configuration.commandName == "opencode" })
        let help = HelpDispatch.text(.root, palette: colorOffPalette)
        #expect(help.contains("opencode"))
        #expect(HelpDispatch.topic(arguments: ["opencode", "--help"]) != nil)
        #expect(HelpDispatch.topic(arguments: ["opencode", "--", "--help"]) == nil)
        #expect(HelpDispatch.topic(arguments: ["opencode", "run", "--help"]) == nil)
    }

    @Test func helpDescribesProxiedNetworkNotDeniedNetwork() {
        let help = HelpDispatch.text(.opencode, palette: colorOffPalette)
        #expect(help.contains("Network is denied") == false)
        #expect(help.contains("RV proxy"))
    }

    @Test func resolve_explicitRelativeExecutableRejected() {
        let result = OpenCodeRun.resolveExecutable("bin/sh", environment: ["PATH": "/usr/bin:/bin"])
        #expect(result == .failure(.executableMustBeAbsolute))
    }

    @Test func resolve_explicitMissingExecutableUnavailable() {
        let result = OpenCodeRun.resolveExecutable(
            "/nonexistent/opencode",
            environment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(result == .failure(.executableUnavailable))
    }

    @Test func resolve_relativePATHEntriesNeverResolve() throws {
        let bin = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-opencode-resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let executable = bin.appendingPathComponent("opencode")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        // Agent executable lookup never searches the current directory, even
        // when a relative entry would match.
        #expect(
            OpenCodeRun.resolveExecutable(nil, environment: ["PATH": ":.:relative"])
                == .failure(.executableUnavailable)
        )
        let resolved = try OpenCodeRun.resolveExecutable(nil, environment: ["PATH": "relative:\(bin.path)"]).get()
        #expect(resolved == executable.resolvingSymlinksInPath().path)
    }

    @Test func run_explicitRelativeExecutableRejectedBeforeLaunch() async throws {
        var command = try openCodeCommand([
            "--executable", "bin/sh", "--workspace", "/tmp",
        ])
        // No PATH resolution may reinterpret an explicit executable, and no
        // host is contacted: this throws on every platform.
        do {
            try await command.run()
            Issue.record("an explicit executable must be absolute")
        } catch is ValidationError {
        }
    }

    @Test func run_unresolvableExecutableRejectedBeforeLaunch() async throws {
        let context = CLIProcess.Context(
            environment: ["PATH": ":.:relative"],
            workspacePath: FileManager.default.temporaryDirectory.path
        )
        try await CLIProcess.$context.withValue(context) {
            var command = try openCodeCommand([])
            do {
                try await command.run()
                Issue.record("empty or relative PATH entries must not resolve the agent")
            } catch is ValidationError {
            }
        }
    }
}

#if os(macOS)
/// `rv opencode` through the real `rv` binary: the frontend must attach to
/// the persistent workspace host instead of owning a workspace.
@Suite("OpenCode frontend", .serialized)
struct OpenCodeFrontendTests {
    @Test func frontend_runsOnThePersistentHost() throws {
        let fixture = try OpenCodeFrontendFixture()
        defer { fixture.remove() }
        let started = try runRV(
            ["workspace", "start", "--workspace", fixture.workspace.path],
            environment: fixture.environment
        )
        #expect(started.status == 0)
        let before = try #require(workspaceUUID(in: started.stdout))

        let script = "printf '%s' \"$1\" > \"$2\"; if printf escape > \"$3\"; then exit 90; fi"
        let inside = fixture.workspace.appendingPathComponent("inside")
        let outside = fixture.root.appendingPathComponent("outside")
        let launched = try runRV(
            [
                "opencode", "--executable", "/bin/sh", "--workspace", fixture.workspace.path,
                "--", "-c", script, "sh", "value with --help and spaces", inside.path, outside.path,
            ],
            environment: fixture.environment
        )
        #expect(launched.status == 0)
        #expect(try String(contentsOf: inside, encoding: .utf8) == "value with --help and spaces")
        #expect(FileManager.default.fileExists(atPath: outside.path) == false)

        // The host outlives the command and still owns the same workspace:
        // the frontend published nothing and mounted nothing.
        let status = try runRV(
            ["workspace", "status", "--workspace", fixture.workspace.path],
            environment: fixture.environment
        )
        #expect(status.status == 0)
        #expect(workspaceUUID(in: status.stdout) == before)
        #expect(status.stdout.contains("phase active"))
    }

    @Test func frontend_childExitStatusPropagates() throws {
        let fixture = try OpenCodeFrontendFixture()
        defer { fixture.remove() }
        let launched = try runRV(
            [
                "opencode", "--executable", "/bin/sh", "--workspace", fixture.workspace.path,
                "--", "-c", "exit 37",
            ],
            environment: fixture.environment
        )
        #expect(launched.status == 37)
    }

    @Test func frontend_defaultExecutableSearchesAbsolutePATH() throws {
        let fixture = try OpenCodeFrontendFixture()
        defer { fixture.remove() }
        let bin = fixture.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("opencode")
        try "#!/bin/sh\nprintf installed > marker\n".write(
            to: executable, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var environment = fixture.environment
        environment["PATH"] = "relative:\(bin.path)"
        let launched = try runRV(
            ["opencode", "--workspace", fixture.workspace.path],
            environment: environment
        )
        #expect(launched.status == 0)
        let marker = fixture.workspace.appendingPathComponent("marker")
        #expect(try String(contentsOf: marker, encoding: .utf8) == "installed")
    }

    @Test func frontend_longCommandLineSurvivesTheControlProtocol() throws {
        let fixture = try OpenCodeFrontendFixture()
        defer { fixture.remove() }
        // 4 KiB single argument: past the old 256-byte cliff, inside the
        // documented 8192-byte bound.
        let payload = String(repeating: "a", count: 4096)
        let marker = fixture.workspace.appendingPathComponent("long.txt")
        let launched = try runRV(
            [
                "opencode", "--executable", "/bin/sh", "--workspace", fixture.workspace.path,
                "--", "-c", "printf '%s' \"$1\" > \"$2\"", "sh", payload, marker.path,
            ],
            environment: fixture.environment
        )
        #expect(launched.status == 0)
        #expect(try String(contentsOf: marker, encoding: .utf8) == payload)
    }

    @Test func frontend_missingWorkspaceDoesNotRunCommand() throws {
        let fixture = try OpenCodeFrontendFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing").path
        let marker = fixture.root.appendingPathComponent("not-run")
        let launched = try runRV(
            [
                "opencode", "--executable", "/bin/sh", "--workspace", missing,
                "--", "-c", "printf escape > \"$1\"", "sh", marker.path,
            ],
            environment: fixture.environment
        )
        #expect(launched.status != 0)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }

    @Test func frontend_matchesWorkspaceRunEnvironment() throws {
        let fixture = try OpenCodeFrontendFixture()
        defer { fixture.remove() }
        let viaRun = try runRV(
            ["workspace", "run", "--workspace", fixture.workspace.path, "--", "/usr/bin/env"],
            environment: fixture.environment
        )
        #expect(viaRun.status == 0)
        let viaOpencode = try runRV(
            ["opencode", "--executable", "/usr/bin/env", "--workspace", fixture.workspace.path],
            environment: fixture.environment
        )
        #expect(viaOpencode.status == 0)
        // Same host, same workspace, same invoking environment: the two
        // frontends must observe the identical cage environment.
        #expect(normalizedEnvironment(viaRun.stdout) == normalizedEnvironment(viaOpencode.stdout))
        #expect(normalizedEnvironment(viaRun.stdout).isEmpty == false)
    }
}
#else
@Suite("OpenCode frontend")
struct OpenCodeFrontendTests {
    @Test func frontend_linuxRefusesWithoutAHost() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-opencode-linux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let launched = try runRV(
            ["opencode", "--executable", "/bin/sh", "--workspace", home.path, "--", "-c", "exit 0"],
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        )
        #expect(launched.status != 0)
        #expect(launched.stderr.contains("contained workspace host is unavailable"))
    }
}
#endif

private func openCodeCommand(_ arguments: [String]) throws -> any AsyncParsableCommand {
    try #require(RV.parseAsRoot(["opencode"] + arguments) as? any AsyncParsableCommand)
}

private struct OpenCodeFrontendFixture {
    let root: URL
    let workspace: URL
    let home: URL
    let environment: [String: String]

    init() throws {
        // Rooted at the shared system temp, NOT the per-user temp: the
        // per-user temp dir is sanctioned tool-temp, so the outside-fence
        // probe must live where the fence actually holds.
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("rv-opencode-frontend-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
        ]
    }

    func remove() {
        if let rv = try? builtRV() {
            let close = Process()
            close.executableURL = rv
            close.arguments = ["workspace", "close", "--workspace", workspace.path]
            close.environment = environment
            close.standardInput = FileHandle.nullDevice
            close.standardOutput = FileHandle.nullDevice
            close.standardError = FileHandle.nullDevice
            do {
                try close.run()
                close.waitUntilExit()
            } catch {
            }
        }
        try? FileManager.default.removeItem(at: root)
    }
}

private struct RVRun {
    var status: Int32
    var stdout: String
    var stderr: String
}

private func runRV(
    _ arguments: [String],
    environment: [String: String],
    seconds: TimeInterval = 180
) throws -> RVRun {
    let rv = try builtRV()
    let process = Process()
    process.executableURL = rv
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let deadline = Date().addingTimeInterval(seconds)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 1)
        if process.isRunning {
            process.interrupt()
        }
        Issue.record("rv \(arguments.first ?? "") timed out after \(Int(seconds))s: \(arguments.joined(separator: " "))")
    }
    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return RVRun(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

private func builtRV() throws -> URL {
    try builtCLIProduct("rv")
}

private func builtCLIProduct(_ name: String) throws -> URL {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    var candidates = [
        root.appendingPathComponent(".build/out/Products/Debug/\(name)"),
        root.appendingPathComponent(".build/debug/\(name)"),
        root.appendingPathComponent(".build/arm64-apple-macosx/debug/\(name)"),
    ]
    var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<8 {
        candidates.append(directory.appendingPathComponent(name))
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
    }
    if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
        return found
    }
    Issue.record("missing built product \(name)")
    throw OpenCodeFrontendError.missingProduct
}

private enum OpenCodeFrontendError: Error {
    case missingProduct
}

private func workspaceUUID(in output: String) -> String? {
    for line in output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("workspace ") {
            return String(trimmed.dropFirst("workspace ".count))
        }
    }
    return nil
}

private func normalizedEnvironment(_ output: String) -> [String] {
    output
        .replacingOccurrences(of: "\r", with: "")
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.contains("=") }
        .sorted()
}
