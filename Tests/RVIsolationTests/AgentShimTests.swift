import Foundation
import RVDomain
import Testing
@testable import RVIsolation

@Test func agentShimDirectoryIsASiblingOfTheHostBinary() {
    #expect(AgentShim.directory(executablePath: "/opt/rv/bin/rv-workspace-host") == "/opt/rv/bin/rv-agent-shims")
    #expect(AgentShim.names == ["claude", "codex", "muse", "opencode"])
}

@Test func agentShimInstallRequiresEveryShimExecutable() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-agent-shims-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(AgentShim.isInstalled(at: root.path) == false)
    for name in AgentShim.names {
        let url = root.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 127\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    #expect(AgentShim.isInstalled(at: root.path))
    try FileManager.default.removeItem(at: root.appendingPathComponent("muse"))
    #expect(AgentShim.isInstalled(at: root.path) == false)
}

@Test func agentShimProfileAdmitsOnlyTheFourKnownFiles() throws {
    let workspace = try #require(WorkingDirectory(validating: "/workspace"))
    let plan = try compileIsolationPlan(
        IsolationCompileRequest(requested: .contained, workspace: workspace)
    ).get()
    let profile = try compileSeatbeltProfile(plan).get()
    #expect(profile.allowingAgentShims(directory: nil).source == profile.source)
    let admitted = profile.allowingAgentShims(directory: "/opt/rv/bin/rv-agent-shims")
    for name in AgentShim.names {
        #expect(admitted.source.contains("(literal \"/opt/rv/bin/rv-agent-shims/\(name)\")"))
    }
    #expect(admitted.source.contains("(allow network") == false)
    #expect(admitted.source.contains("(deny default)"))
}

@Test func agentShimScriptsGuideToOutsideAndExit127() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    for name in AgentShim.names {
        let shim = root.appendingPathComponent("AgentShims/\(name)")
        #expect(FileManager.default.isExecutableFile(atPath: shim.path))
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/sh")
        run.arguments = [shim.path]
        let error = Pipe()
        run.standardError = error
        run.standardOutput = FileHandle.nullDevice
        try run.run()
        run.waitUntilExit()
        #expect(run.terminationStatus == 127)
        let text = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(text.contains(name))
        #expect(text.contains("normal terminal"))
    }
}
