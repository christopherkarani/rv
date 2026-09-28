import ArgumentParser
import Foundation
import RVIsolation
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

    @Test func launch_realShellPreservesArgumentsAndDeniesOutsideWrite() async throws {
        let fixture = try OpenCodeCommandFixture()
        defer { fixture.remove() }
        let inside = fixture.workspace.appendingPathComponent("inside")
        let outside = fixture.root.appendingPathComponent("outside")
        let script = "printf '%s' \"$1\" > \"$2\"; if printf escape > \"$3\"; then exit 90; fi"
        let arguments = [
            "--executable", "/bin/sh", "--workspace", fixture.workspace.path,
            "--", "-c", script, "sh", "value with --help and spaces", inside.path, outside.path,
        ]

        #if os(macOS)
        #expect(try runInstalledOpenCode(arguments) == 0)
        #else
        var command = try openCodeCommand(arguments)
        guard try await launchedOrRefusedOnLinux(&command, absent: [inside, outside]) else { return }
        #endif

        #expect(try String(contentsOf: inside, encoding: .utf8) == "value with --help and spaces")
        #expect(FileManager.default.fileExists(atPath: outside.path) == false)
        #if os(macOS)
        guard case .live(let endpoint) = WorkspaceHosts.inspect(project: fixture.workspace.path) else {
            Issue.record("rv opencode must leave a persistent workspace host")
            return
        }
        let client = try WorkspaceClient.connect(endpoint).get()
        #expect(try client.listRuntimes().get().count == 1)
        _ = client.detach()
        #endif
    }

    @Test func launch_childExitStatusPropagates() async throws {
        let fixture = try OpenCodeCommandFixture()
        defer { fixture.remove() }
        let arguments = [
            "--executable", "/bin/sh", "--workspace", fixture.workspace.path,
            "--", "-c", "exit 37",
        ]
        #if os(macOS)
        #expect(try runInstalledOpenCode(arguments) == 37)
        #else
        var command = try openCodeCommand(arguments)
        do {
            try await command.run()
            Issue.record("the child exit status must propagate")
        } catch let error as ExitCode {
            #expect(error.rawValue == 37)
        } catch let error as ValidationError {
            #expect(String(describing: error).contains("contained workspace host is unavailable"))
        }
        #endif
    }

    @Test func launch_missingWorkspaceDoesNotRunCommand() async throws {
        let fixture = try OpenCodeCommandFixture()
        defer { fixture.remove() }
        let marker = fixture.workspace.appendingPathComponent("not-run")
        var command = try openCodeCommand([
            "--executable", "/bin/sh",
            "--workspace", fixture.root.appendingPathComponent("missing").path,
            "--", "-c", "printf escape > \"$1\"", "sh", marker.path,
        ])
        do {
            try await command.run()
            Issue.record("sandbox preparation failure must stop the command")
        } catch is ValidationError {
            #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        }
    }

    @Test func launch_explicitRelativeExecutableRejected() async throws {
        let fixture = try OpenCodeCommandFixture()
        defer { fixture.remove() }
        var command = try openCodeCommand([
            "--executable", "bin/sh", "--workspace", fixture.workspace.path,
        ])
        do {
            try await command.run()
            Issue.record("an explicit executable must be absolute")
        } catch is ValidationError {
            // No PATH resolution may reinterpret an explicit executable.
        }
    }

    @Test func launch_defaultExecutableUsesAbsolutePATHAndCurrentWorkspace() async throws {
        let fixture = try OpenCodeCommandFixture()
        defer { fixture.remove() }
        let bin = fixture.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("opencode")
        try "#!/bin/sh\nprintf installed > marker\n".write(
            to: executable, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let context = CLIProcess.Context(
            environment: ["PATH": "relative:\(bin.path)"],
            workspacePath: fixture.workspace.path
        )
        let marker = fixture.workspace.appendingPathComponent("marker")
        #if os(macOS)
        #expect(try runInstalledOpenCode(
            [],
            environment: context.environment,
            currentDirectory: fixture.workspace
        ) == 0)
        #else
        let launched = try await CLIProcess.$context.withValue(context) {
            var command = try openCodeCommand([])
            return try await launchedOrRefusedOnLinux(&command, absent: [marker])
        }
        guard launched else { return }
        #endif
        #expect(try String(contentsOf: marker, encoding: .utf8) == "installed")
    }

    @Test func launch_relativePATHDoesNotResolveExecutable() async throws {
        let fixture = try OpenCodeCommandFixture()
        defer { fixture.remove() }
        let context = CLIProcess.Context(
            environment: ["PATH": ":.:relative"],
            workspacePath: fixture.workspace.path
        )
        try await CLIProcess.$context.withValue(context) {
            var command = try openCodeCommand([])
            do {
                try await command.run()
                Issue.record("empty or relative PATH entries must not resolve the agent")
            } catch is ValidationError {
                // Agent executable lookup never searches the current directory.
            }
        }
    }
}

#if os(macOS)
private func runInstalledOpenCode(
    _ arguments: [String],
    environment: [String: String]? = nil,
    currentDirectory: URL? = nil
) throws -> Int32 {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let executable = repository.appendingPathComponent(".build/debug/rv")
    let host = repository.appendingPathComponent(".build/debug/rv-workspace-host")
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
    #expect(FileManager.default.isExecutableFile(atPath: host.path))
    let process = Process()
    process.executableURL = executable
    process.arguments = ["opencode"] + arguments
    process.currentDirectoryURL = currentDirectory
    if let environment {
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
#endif

private func launchedOrRefusedOnLinux(
    _ command: inout any AsyncParsableCommand,
    absent: [URL]
) async throws -> Bool {
    do {
        try await command.run()
        #if os(Linux)
        Issue.record("Linux rv opencode must refuse the contained launch")
        return false
        #else
        return true
        #endif
    } catch let status as ExitCode {
        #if os(Linux)
        Issue.record("Linux rv opencode must refuse the contained launch: \(status)")
        return false
        #else
        #expect(status.rawValue == 0)
        return status.rawValue == 0
        #endif
    } catch let error as ValidationError {
        #if os(Linux)
        #expect(String(describing: error).contains("contained workspace host is unavailable"))
        for url in absent {
            #expect(FileManager.default.fileExists(atPath: url.path) == false)
        }
        return false
        #else
        throw error
        #endif
    }
}

private func openCodeCommand(_ arguments: [String]) throws -> any AsyncParsableCommand {
    try #require(RV.parseAsRoot(["opencode"] + arguments) as? any AsyncParsableCommand)
}

private struct OpenCodeCommandFixture {
    let root: URL
    let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-opencode-command-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    func remove() {
        #if os(macOS)
        if case .live(let endpoint) = WorkspaceHosts.inspect(project: workspace.path),
            case .success(let client) = WorkspaceClient.connect(endpoint)
        {
            _ = client.closeWorkspace()
        }
        #endif
        try? FileManager.default.removeItem(at: root)
    }
}
