import Foundation
import RVDomain
import Testing
@testable import RVIsolation

@Test func agentBinDirectoryIsASiblingOfTheHostBinary() {
    #expect(AgentBin.directory(executablePath: "/opt/rv/bin/rv-workspace-host") == "/opt/rv/bin/rv-agent-bin")
    #expect(AgentBin.names == ["claude", "codex", "muse", "opencode", "node"])
}

private struct AgentBinFixture {
    let bin: URL
    let home: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-agent-bin-\(UUID().uuidString)", isDirectory: true)
        bin = root.appendingPathComponent("rv-agent-bin", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: bin.deletingLastPathComponent())
    }

    func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

@Test func agentBinResolutionGrantsOnlyResolvedAgents() throws {
    let fixture = try AgentBinFixture()
    defer { fixture.tearDown() }
    // claude resolves; codex resolves with a package tree; opencode is a
    // dead link and grants nothing; muse and node are absent.
    let claudeTarget = fixture.home.appendingPathComponent("tools/claude-bin")
    try fixture.makeExecutable(at: claudeTarget)
    try FileManager.default.createSymbolicLink(
        at: fixture.bin.appendingPathComponent("claude"), withDestinationURL: claudeTarget
    )
    let codexTarget = fixture.home.appendingPathComponent("pkg/bin/codex.js")
    try fixture.makeExecutable(at: codexTarget)
    try FileManager.default.createSymbolicLink(
        at: fixture.bin.appendingPathComponent("codex"), withDestinationURL: codexTarget
    )
    try FileManager.default.createSymbolicLink(
        atPath: fixture.bin.appendingPathComponent("opencode").path,
        withDestinationPath: fixture.home.appendingPathComponent("gone").path
    )
    let codexAuth = fixture.home.appendingPathComponent(".codex/auth.json")
    try FileManager.default.createDirectory(
        at: codexAuth.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: codexAuth)
    let codexConfig = fixture.home.appendingPathComponent(".codex/config.toml")
    try Data("".utf8).write(to: codexConfig)
    let claudeAuth = fixture.home.appendingPathComponent(".claude/.credentials.json")
    try FileManager.default.createDirectory(
        at: claudeAuth.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: claudeAuth)
    let claudeSettings = fixture.home.appendingPathComponent(".claude/settings.json")
    try Data("{}".utf8).write(to: claudeSettings)

    let resolution = AgentBin.resolve(binDirectory: fixture.bin.path, home: fixture.home.path)
    // Resolution realpaths every target (/var resolves under /private/var).
    let claudeReal = try #require(posixRealpath(claudeTarget.path))
    let codexReal = try #require(posixRealpath(codexTarget.path))
    let packageReal = try #require(posixRealpath(fixture.home.appendingPathComponent("pkg").path))
    #expect(resolution.directory == fixture.bin.path)
    #expect(resolution.executables.contains("\(fixture.bin.path)/claude"))
    #expect(resolution.executables.contains(claudeReal))
    #expect(resolution.executables.contains("\(fixture.bin.path)/codex"))
    #expect(resolution.executables.contains(codexReal))
    #expect(resolution.executables.contains(where: { $0.contains("opencode") }) == false)
    #expect(resolution.executables.contains(where: { $0.contains("muse") }) == false)
    #expect(resolution.trees == [packageReal])
    #expect(resolution.credentials == [claudeAuth.path, claudeSettings.path, codexAuth.path, codexConfig.path])
    #expect(resolution.writableTrees == AgentHomeStaging.claudeScratchRoots())
}

@Test func agentBinResolutionOmitsClaudeScratchWhenClaudeIsAbsent() throws {
    let fixture = try AgentBinFixture()
    defer { fixture.tearDown() }
    let resolution = AgentBin.resolve(binDirectory: fixture.bin.path, home: fixture.home.path)
    #expect(resolution.writableTrees.isEmpty)
    #expect(AgentHomeStaging.claudeScratchRoots().count == 2)
}

@Test func agentBinResolutionAdmitsMuseInstallFiles() throws {
    let fixture = try AgentBinFixture()
    defer { fixture.tearDown() }
    let install = fixture.home.appendingPathComponent("minstall")
    let script = install.appendingPathComponent("muse")
    try fixture.makeExecutable(at: script)
    try Data("1.0\n".utf8).write(to: install.appendingPathComponent(".muse-version"))
    try fixture.makeExecutable(at: install.appendingPathComponent("muse-bin-1.0"))
    try Data("x".utf8).write(to: install.appendingPathComponent("unrelated.txt"))
    try FileManager.default.createSymbolicLink(
        at: fixture.bin.appendingPathComponent("muse"), withDestinationURL: script
    )
    let auth = fixture.home.appendingPathComponent(".config/muse/auth.json")
    try FileManager.default.createDirectory(
        at: auth.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: auth)

    let resolution = AgentBin.resolve(binDirectory: fixture.bin.path, home: fixture.home.path)
    let installReal = try #require(posixRealpath(install.path))
    #expect(resolution.executables.contains("\(installReal)/muse-bin-1.0"))
    #expect(resolution.executables.contains("\(installReal)/.muse-version"))
    #expect(resolution.executables.contains(where: { $0.contains("unrelated") }) == false)
    #expect(resolution.credentials == [auth.path])
}

@Test func agentBinProfileGrantsFilesTreesAndReadOnlyCredentials() throws {
    let workspace = try #require(WorkingDirectory(validating: "/workspace"))
    let plan = try compileIsolationPlan(
        IsolationCompileRequest(requested: .contained, workspace: workspace)
    ).get()
    let profile = try compileSeatbeltProfile(plan).get()
    let admitted = profile.allowingAgentBin(
        AgentBinResolution(
            directory: "/opt/rv/bin/rv-agent-bin",
            executables: ["/opt/rv/bin/rv-agent-bin/claude", "/home/tools/claude-bin"],
            trees: ["/home/pkg"],
            credentials: ["/home/.codex/auth.json"],
            writableTrees: ["/tmp/claude-501"]
        )
    )
    #expect(admitted.source.contains("(literal \"/opt/rv/bin/rv-agent-bin\")"))
    #expect(admitted.source.contains("(literal \"/opt/rv/bin/rv-agent-bin/claude\")"))
    #expect(admitted.source.contains("(literal \"/home/tools/claude-bin\")"))
    #expect(admitted.source.contains("(subpath \"/home/pkg\")"))
    #expect(admitted.source.contains("(allow file-read-data"))
    #expect(admitted.source.contains("(literal \"/home/.codex/auth.json\")"))
    #expect(admitted.source.contains("(allow file-read* file-write*"))
    #expect(admitted.source.contains("(subpath \"/tmp/claude-501\")"))
    #expect(admitted.source.contains("(deny default)"))
}

@Test func stageAgentHomesLinksClaudeCredentials() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-stage-homes-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let cageHome = root.appendingPathComponent("cage-home", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cageHome, withIntermediateDirectories: true)
    let source = home.appendingPathComponent(".claude/.credentials.json")
    try FileManager.default.createDirectory(
        at: source.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: source)
    let settingsSource = home.appendingPathComponent(".claude/settings.json")
    try Data("{}".utf8).write(to: settingsSource)

    stageAgentHomes(cageHome: cageHome.path, hostHome: home.path)

    let link = cageHome.appendingPathComponent(".claude/.credentials.json")
    #expect(FileManager.default.fileExists(atPath: link.path))
    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    #expect(destination == source.path)
    let settingsLink = cageHome.appendingPathComponent(".claude/settings.json")
    #expect(FileManager.default.fileExists(atPath: settingsLink.path))
    let settingsDestination = try FileManager.default.destinationOfSymbolicLink(atPath: settingsLink.path)
    #expect(settingsDestination == settingsSource.path)
}

@Test func preparedContainedProfileAdmitsLoopbackOnly() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-agent-loopback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try #require(WorkingDirectory(validating: root.path))
    let plan = try compileIsolationPlan(
        IsolationCompileRequest(requested: .contained, workspace: workspace)
    ).get()
    let command = try #require(IsolatedCommand(executable: "/bin/zsh"))
    let request = try prepareSeatbelt(plan, command).get()
    let profile = try #require(request.seatbeltProfile)
    #expect(profile.source.contains("(allow network-outbound"))
    #expect(profile.source.contains("(remote tcp \"localhost:*\")"))
    #expect(profile.source.contains("(allow network*)") == false)
    #expect(profile.source.contains("(allow network-outbound)") == false)
}
