#if canImport(Darwin)
import Darwin
#endif
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Authority is the operator's explicit profile ID plus the project it is
/// bound to. Executable names, presets, and detection metadata select nothing.
@Test func unknownResourceProfileIDResolvesToNothing() {
    let policy = RuntimeResourcePolicy(profiles: [
        RuntimeResourceProfile(id: "alpha", projects: ["/tmp/project-a"]),
    ])
    #expect(policy.profile(id: "no-such-profile", project: "/tmp/project-a") == nil)
    #expect(policy.profile(id: "", project: "/tmp/project-a") == nil)
    #expect(policy.profile(id: "ALPHA", project: "/tmp/project-a") == nil)
    #expect(RuntimeResourcePolicy.empty.profile(id: "alpha", project: "/tmp/project-a") == nil)
}

@Test func profileBoundToProjectAIsUnresolvableForProjectB() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-adversarial-projects-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let projectA = root.appendingPathComponent("project-a").path
    let projectB = root.appendingPathComponent("project-b").path
    try FileManager.default.createDirectory(atPath: projectA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: projectB, withIntermediateDirectories: true)
    let policy = RuntimeResourcePolicy(profiles: [
        RuntimeResourceProfile(id: "alpha", projects: [projectA]),
    ])
    #expect(policy.profile(id: "alpha", project: projectA) != nil)
    #expect(policy.profile(id: "alpha", project: projectB) == nil)
    #expect(policy.profile(id: "alpha", project: projectA + "-suffix") == nil)
}

@Test func agentNamedExecutableWithNoProfileStagesZeroResources() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-adversarial-agentname-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
    let binURL = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
    for name in ["claude", "codex"] {
        let url = binURL.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    let workspace = try #require(WorkingDirectory(validating: workspaceURL.path))
    let plan = try compileIsolationPlan(
        IsolationCompileRequest(requested: .contained, workspace: workspace)
    ).get()
    for name in ["claude", "codex"] {
        let command = try #require(IsolatedCommand(
            executable: binURL.appendingPathComponent(name).path
        ))
        let prepared = try prepareSeatbelt(plan, command).get()
        #expect(prepared.resources == nil)
        let profile = try #require(prepared.seatbeltProfile)
        #expect(profile.source.contains("rv-runtime-") == false)
        #expect(profile.source.contains("rv-agent-bin") == false)
        #expect(profile.source.contains("(deny default)"))
    }
}

@Test func symlinkedCredentialSourceEscapeFailsClosedStaging() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-adversarial-escape-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = root.appendingPathComponent("vault", isDirectory: true)
    let drop = root.appendingPathComponent("drop", isDirectory: true)
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
    let original = vault.appendingPathComponent("synthetic-secret.auth")
    try Data("synthetic-secret".utf8).write(to: original)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
    let escape = drop.appendingPathComponent("evil.auth")
    try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: original)
    let profile = RuntimeResourceProfile(
        id: "evil", projects: [root.path],
        credentials: [.init(source: escape.path, destination: "staged.auth")]
    )
    let manifest = RuntimeResourceManifest(profile)
    defer { manifest.remove() }
    #expect(manifest.stage().isFailure(.credential(destination: "staged.auth")))
    #expect(FileManager.default.fileExists(atPath: manifest.privateHome) == false)
    #expect(try String(contentsOf: original, encoding: .utf8) == "synthetic-secret")
}

#if os(macOS)
@Test func ambientSecretsDoNotFlowUnlessExplicitlyNamed() {
    let host = [
        "ANTHROPIC_API_KEY": "synthetic-ambient-secret",
        "HOME": "/Users/operator",
        "PATH": "/usr/bin:/bin",
    ]
    for io in [IsolatedIO.discard, .inherit, .pseudoTerminal(rows: 24, columns: 80)] {
        let bare = containedRuntimeEnvironment(workspace: "/tmp/ws", io: io, hostEnvironment: host)
        #expect(bare.contains("PATH=/usr/bin:/bin"))
        #expect(bare.contains("HOME=/tmp/ws"))
        #expect(bare.allSatisfy { !$0.hasPrefix("ANTHROPIC_API_KEY=") })
        let empty = RuntimeResourceManifest(
            RuntimeResourceProfile(id: "empty", projects: ["/tmp/ws"])
        )
        let staged = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: io, resources: empty, hostEnvironment: host
        )
        #expect(staged.allSatisfy { !$0.hasPrefix("ANTHROPIC_API_KEY=") })
    }
    let mapped = RuntimeResourceManifest(RuntimeResourceProfile(
        id: "mapped", projects: ["/tmp/ws"],
        environment: [.init(name: "GATEWAY_KEY", hostVariable: "ANTHROPIC_API_KEY")]
    ))
    let mappedValues = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .discard, resources: mapped, hostEnvironment: host
    )
    #expect(mappedValues.contains("GATEWAY_KEY=synthetic-ambient-secret"))
    #expect(mappedValues.allSatisfy { !$0.hasPrefix("ANTHROPIC_API_KEY=") })
    let literal = RuntimeResourceManifest(RuntimeResourceProfile(
        id: "literal", projects: ["/tmp/ws"],
        environment: [.init(name: "TOOL_NO_UPDATE", literalValue: "1")]
    ))
    let literalValues = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .discard, resources: literal, hostEnvironment: [:]
    )
    #expect(literalValues.contains("TOOL_NO_UPDATE=1"))
}

@Test(.disabled("TRANSITIONAL-PEER-AUTH: code-identity roles reject test binaries and scoped operator permits deny launch/terminal ops; re-enable when test trust + permits land")) func forgedAndCrossProjectProfileIDsFailClosedAtServer() throws {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let config = tree.rootURL.appendingPathComponent("config", isDirectory: true)
    let projectADir = tree.rootURL.appendingPathComponent("project-a", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectADir, withIntermediateDirectories: true)
    let canonicalA = try #require(posixRealpath(projectADir.path))
    let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
    let supervisor = try WorkspaceSessionSupervisor.open(
        directory, lifecycleLog: .file(config.appendingPathComponent("life.jsonl"))
    ).get()
    let projectB = supervisor.snapshot.originalPath.rawValue
    #expect(projectB != canonicalA)
    let policy = RuntimeResourcePolicy(profiles: [
        RuntimeResourceProfile(id: "alpha", projects: [canonicalA]),
    ])
    let server = try WorkspaceHostServer.start(
        supervisor: supervisor, configurationDirectory: config,
        sessionStore: .file(config.appendingPathComponent("runtime.jsonl")),
        resourcePolicy: policy,
    admission: .failClosed
    ).get()
    defer { server.stop(); _ = supervisor.close() }
    let client = try WorkspaceClient.connect(server.endpoint).get()
    let marker = tree.workspaceURL.appendingPathComponent("must-not-exist")
    #expect(client.launchRuntime(
        executable: "/bin/sh", arguments: ["-c", "touch must-not-exist"],
        resourceProfileID: "forged-id"
    ).isFailure(.resourceProfileUnavailable))
    #expect(client.launchRuntime(
        executable: "/bin/sh", arguments: ["-c", "touch must-not-exist"],
        resourceProfileID: "alpha"
    ).isFailure(.resourceProfileUnavailable))
    #expect(FileManager.default.fileExists(atPath: marker.path) == false)
}

@Test(.disabled("TRANSITIONAL-PEER-AUTH: code-identity roles reject test binaries and scoped operator permits deny launch/terminal ops; re-enable when test trust + permits land")) func defaultProfileNeverAutoAttachesNilLaunchKeepsBaseFence() throws {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let config = tree.rootURL.appendingPathComponent("config", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let secret = tree.rootURL.appendingPathComponent("credential-default")
    try Data("synthetic-default".utf8).write(to: secret)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
    let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
    let supervisor = try WorkspaceSessionSupervisor.open(
        directory, lifecycleLog: .file(config.appendingPathComponent("life.jsonl"))
    ).get()
    let project = supervisor.snapshot.originalPath.rawValue
    let policy = RuntimeResourcePolicy(
        profiles: [
            RuntimeResourceProfile(
                id: "alpha", projects: [project],
                credentials: [.init(source: secret.path, destination: ".config/auth")]
            ),
        ],
        defaultProfile: "alpha"
    )
    let server = try WorkspaceHostServer.start(
        supervisor: supervisor, configurationDirectory: config,
        sessionStore: .file(config.appendingPathComponent("runtime.jsonl")),
        resourcePolicy: policy,
    admission: .failClosed
    ).get()
    defer { server.stop(); _ = supervisor.close() }
    let client = try WorkspaceClient.connect(server.endpoint).get()

    _ = try client.launchRuntime(
        executable: "/bin/sh",
        arguments: [
            "-c",
            "if cat \"$HOME/.config/auth\" >/dev/null 2>&1; then echo leak > nil-leak.txt; fi; "
                + "printf launched > nil-launched.txt",
        ]
    ).get()
    // The marker prints last, so its presence proves the leak branch ran.
    #expect(resourceProbeWaitFor(tree.workspaceURL.appendingPathComponent("nil-launched.txt")))
    #expect(FileManager.default.fileExists(atPath: tree.workspaceURL.appendingPathComponent("nil-leak.txt").path)
        == false)

    _ = try client.launchRuntime(
        executable: "/bin/sh",
        arguments: ["-c", "cat \"$HOME/.config/auth\" > picked-selected.txt"],
        resourceProfileID: "alpha"
    ).get()
    // Poll for content, not mere existence: the shell creates the file
    // before `cat` finishes writing it.
    #expect(resourceProbeWaitForContent(
        tree.workspaceURL.appendingPathComponent("picked-selected.txt"), equals: "synthetic-default"
    ))
}

@Test(.disabled("TRANSITIONAL-PEER-AUTH: code-identity roles reject test binaries and scoped operator permits deny launch/terminal ops; re-enable when test trust + permits land")) func profileStagingFailureKeepsLaunchFailurePath() throws {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let config = tree.rootURL.appendingPathComponent("config", isDirectory: true)
    let vault = tree.rootURL.appendingPathComponent("vault", isDirectory: true)
    let drop = tree.rootURL.appendingPathComponent("drop", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
    let original = vault.appendingPathComponent("synthetic-secret.auth")
    try Data("synthetic-secret".utf8).write(to: original)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
    let escape = drop.appendingPathComponent("evil.auth")
    try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: original)
    let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
    let supervisor = try WorkspaceSessionSupervisor.open(
        directory, lifecycleLog: .file(config.appendingPathComponent("life.jsonl"))
    ).get()
    let project = supervisor.snapshot.originalPath.rawValue
    let policy = RuntimeResourcePolicy(profiles: [
        RuntimeResourceProfile(
            id: "evil", projects: [project],
            credentials: [.init(source: escape.path, destination: "staged.auth")]
        ),
    ])
    let server = try WorkspaceHostServer.start(
        supervisor: supervisor, configurationDirectory: config,
        sessionStore: .file(config.appendingPathComponent("runtime.jsonl")),
        resourcePolicy: policy,
    admission: .failClosed
    ).get()
    defer { server.stop(); _ = supervisor.close() }
    let client = try WorkspaceClient.connect(server.endpoint).get()
    let marker = tree.workspaceURL.appendingPathComponent("must-not-spawn")
    let refused = client.launchRuntime(
        executable: "/bin/sh", arguments: ["-c", "touch must-not-spawn"],
        resourceProfileID: "evil"
    )
    // The refusal names the broken grant instead of collapsing to a
    // shapeless invalid request; nothing spawns either way.
    #expect(refused.isFailure(.resourceStagingFailed("credential 'staged.auth'")))
    #expect(refused.isFailure(.invalidRequest) == false)
    #expect(refused.isFailure(.resourceProfileUnavailable) == false)
    #expect(FileManager.default.fileExists(atPath: marker.path) == false)
}

@Test(.disabled("TRANSITIONAL-PEER-AUTH: code-identity roles reject test binaries and scoped operator permits deny launch/terminal ops; re-enable when test trust + permits land")) func ensureTerminalRuntimeAdjudicatesExplicitProfile() throws {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let config = tree.rootURL.appendingPathComponent("config", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
    let supervisor = try WorkspaceSessionSupervisor.open(
        directory, lifecycleLog: .file(config.appendingPathComponent("life.jsonl"))
    ).get()
    let server = try WorkspaceHostServer.start(
        supervisor: supervisor, configurationDirectory: config,
        sessionStore: .file(config.appendingPathComponent("runtime.jsonl")),
    admission: .failClosed
    ).get()
    defer { server.stop(); _ = supervisor.close() }
    let raw = try WorkspaceControlSocket.connect(path: server.endpoint.socketPath, timeout: 2).get()
    defer { close(raw) }
    let hello = WorkspaceControlMessage(
        version: WorkspaceControlLimits.version,
        id: UUID(),
        op: WorkspaceControlOp.hello.rawValue,
        token: server.endpoint.ownerToken
    )
    let helloBody = try #require(WorkspaceControlCodec.encode(hello))
    #expect(WorkspaceControlSocket.writeFrame(fd: raw, body: helloBody))
    _ = try WorkspaceControlSocket.readFrame(fd: raw, timeout: 2).get()
    let ensure = WorkspaceControlMessage(
        version: WorkspaceControlLimits.version,
        id: UUID(),
        op: WorkspaceControlOp.ensureTerminalRuntime.rawValue,
        executable: "/bin/sh",
        arguments: ["-c", "/bin/sleep 30"],
        resourceProfileID: "alpha",
        io: "terminal",
        rows: 24,
        columns: 80
    )
    let ensureBody = try #require(WorkspaceControlCodec.encode(ensure))
    #expect(WorkspaceControlSocket.writeFrame(fd: raw, body: ensureBody))
    let reply = try WorkspaceControlSocket.readFrame(fd: raw, timeout: 10).get()
    guard case .message(let refused) = WorkspaceControlCodec.decode(reply) else {
        Issue.record("ensure with an unknown profile must receive a protocol error")
        return
    }
    // Unknown IDs fail closed at creation; the refusal names the
    // profile, not the request shape.
    #expect(refused.ok == false)
    #expect(refused.error == WorkspaceControlCode.resourceProfileUnavailable.rawValue)
    #expect(supervisor.runtimeFacts().isEmpty)
}

@Test(.disabled("TRANSITIONAL-PEER-AUTH: code-identity roles reject test binaries and scoped operator permits deny launch/terminal ops; re-enable when test trust + permits land")) func ensureTerminalRuntimeAcceptsKnownExplicitProfile() throws {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let config = tree.rootURL.appendingPathComponent("config", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
    let supervisor = try WorkspaceSessionSupervisor.open(
        directory, lifecycleLog: .file(config.appendingPathComponent("life.jsonl"))
    ).get()
    let policy = RuntimeResourcePolicy(profiles: [
        RuntimeResourceProfile(id: "alpha", projects: [supervisor.snapshot.originalPath.rawValue])
    ])
    let server = try WorkspaceHostServer.start(
        supervisor: supervisor, configurationDirectory: config,
        sessionStore: .file(config.appendingPathComponent("runtime.jsonl")),
        resourcePolicy: policy,
    admission: .failClosed
    ).get()
    defer { server.stop(); _ = supervisor.close() }
    let client = try WorkspaceClient.connect(server.endpoint).get()
    defer { _ = client.detach() }
    let ensured = try client.ensureTerminalRuntime(
        executable: "/bin/sh",
        arguments: ["-c", "/bin/sleep 30"],
        terminalRows: 24,
        terminalColumns: 80,
        resourceProfileID: "alpha"
    ).get()
    #expect(ensured.running)
    #expect(ensured.terminal)
    #expect(supervisor.runtimeFacts().contains { $0.id == ensured.runtime })
    let refused = client.ensureTerminalRuntime(
        executable: "/bin/sh",
        arguments: ["-c", "/bin/sleep 30"],
        terminalRows: 24,
        terminalColumns: 80,
        resourceProfileID: "missing"
    )
    // A second ensure reuses the live terminal runtime instead of
    // adjudicating the unknown id: the grant applies at creation.
    #expect(refused.isSuccess)
}
#endif

#if os(macOS)
private func resourceProbeWaitFor(_ url: URL, seconds: TimeInterval = 20) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return FileManager.default.fileExists(atPath: url.path)
}

private func resourceProbeWaitForContent(
    _ url: URL, equals expected: String, seconds: TimeInterval = 20
) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if (try? String(contentsOf: url, encoding: .utf8)) == expected { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return (try? String(contentsOf: url, encoding: .utf8)) == expected
}
#endif
