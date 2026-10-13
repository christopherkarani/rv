import Foundation
import RVDomain
import Testing
@testable import RVIsolation

// F2 legacy credential delivery: default closed. No live host keys or
// credential files reach the cage environment or files unless the operator
// explicitly opts in via the launch configuration.

@Test func gatewayRoutingNamesAllSurviveProjection() {
    // Proof that gateway routing needs no re-injection: every
    // gatewayPassthrough name passes the generic projection, so the
    // projection is its single delivery path.
    for name in AgentHomeStaging.gatewayPassthrough {
        #expect(ContainedEnvironmentPolicy.isBlockedVariableName(name) == false)
        #expect(ContainedEnvironmentPolicy.isManagedByRuntime(name) == false)
    }
    var host: [String: String] = [:]
    for name in AgentHomeStaging.gatewayPassthrough {
        host[name] = "synthetic-value"
    }
    let projected = ContainedEnvironmentPolicy.project(host: host)
    #expect(Set(projected.map(\.0)) == Set(AgentHomeStaging.gatewayPassthrough))
}

@Test func apiKeyNamesStayStrippedByProjection() {
    // The opt-in re-injection is the only cage path for these names: the
    // generic projection always strips them.
    for name in AgentHomeStaging.apiKeyPassthrough {
        #expect(ContainedEnvironmentPolicy.isBlockedVariableName(name))
    }
}

@Test func defaultDenyPathsCoverCompatCredentialPaths() {
    let home = "/Users/operator"
    let denies = ContainedSensitivePaths.denyPaths(hostHome: home, excluding: [])
    // Catalog-covered compat originals stay denied by default ...
    #expect(denies.contains("\(home)/.codex/auth.json"))
    #expect(denies.contains("\(home)/.claude/.credentials.json"))
    #expect(denies.contains("\(home)/.local/share/opencode/auth.json"))
    // ... and lift only under explicit credential-files opt-in.
    let optedIn = ContainedSensitivePaths.denyPaths(
        hostHome: home, excluding: [], credentialDelivery: .legacyOptIn
    )
    #expect(optedIn.contains("\(home)/.codex/auth.json") == false)
    #expect(optedIn.contains("\(home)/.claude/.credentials.json") == false)
    #expect(optedIn.contains("\(home)/.local/share/opencode/auth.json") == false)
    // Unrelated catalog denies are identical either way.
    #expect(denies.contains("\(home)/.ssh"))
    #expect(optedIn.contains("\(home)/.ssh"))
}

@Test func defaultStagingCreatesNoCredentialLinks() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-cred-closed-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let cageHome = root.appendingPathComponent("cage-home", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cageHome, withIntermediateDirectories: true)
    let source = home.appendingPathComponent(".codex/auth.json")
    try FileManager.default.createDirectory(
        at: source.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    // Deliberately dummy content. Never inspect real user credentials.
    try Data("{\"fixture\":\"not-a-secret\"}".utf8).write(to: source)

    stageAgentHomes(cageHome: cageHome.path, hostHome: home.path)

    for link in AgentHomeStaging.credentialLinks {
        #expect(
            FileManager.default.fileExists(atPath: "\(cageHome.path)/\(link.relative)") == false
        )
    }
}

@Test func launchRequestDefaultsToClosedDelivery() throws {
    let workspace = try #require(WorkingDirectory(validating: "/workspace"))
    let plan = try compileIsolationPlan(
        IsolationCompileRequest(requested: .contained, workspace: workspace)
    ).get()
    let command = try #require(IsolatedCommand(executable: "/bin/zsh"))
    let profile = SeatbeltProfile(source: "(version 1)\n(deny default)\n", workspacePath: "/workspace")
    let request = try #require(IsolatedLaunchRequest(
        plan: plan, command: command, launch: .seatbelt(profile)
    ))
    #expect(request.credentialDelivery == .closed)
    #expect(request.withIO(.pseudoTerminal(rows: 24, columns: 80)).credentialDelivery == .closed)
    let optedIn = try #require(IsolatedLaunchRequest(
        plan: plan, command: command, launch: .seatbelt(profile),
        credentialDelivery: .legacyOptIn
    ))
    #expect(optedIn.credentialDelivery == .legacyOptIn)
    #expect(request != optedIn)
}

@Test func prepareThreadsCredentialDeliveryIntoRequest() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-cred-prepare-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try #require(WorkingDirectory(validating: root.path))
    let plan = try compileIsolationPlan(
        IsolationCompileRequest(requested: .contained, workspace: workspace)
    ).get()
    let command = try #require(IsolatedCommand(executable: "/bin/zsh"))
    let closed = try prepareSeatbelt(plan, command).get()
    #expect(closed.credentialDelivery == .closed)
    let optedIn = try prepareSeatbelt(plan, command, credentialDelivery: .legacyOptIn).get()
    #expect(optedIn.credentialDelivery == .legacyOptIn)
    // The resolved denies follow the same flag: compat originals denied
    // by default, lifted only when opted in.
    if let home = ProcessInfo.processInfo.environment["HOME"], isUsableAbsolutePath(home) {
        #expect(closed.productive?.sensitiveDenies.contains("\(home)/.codex/auth.json") == true)
        #expect(optedIn.productive?.sensitiveDenies.contains("\(home)/.codex/auth.json") == false)
    }
}

#if os(macOS)
@Test func defaultCageEnvironmentCarriesNoLiveKeys() {
    let liveMeta = "live-meta-key-value"
    let liveAnthropic = "live-anthropic-key-value"
    let host = [
        "META_API_KEY": liveMeta,
        "ANTHROPIC_API_KEY": liveAnthropic,
        "OPENAI_API_KEY": "live-openai-key-value",
        "GH_TOKEN": "live-token-value",
    ]
    for io in [IsolatedIO.inherit, .pseudoTerminal(rows: 24, columns: 80)] {
        let values = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: io,
            agentBin: "/opt/rv/bin/rv-agent-bin",
            hostEnvironment: host
        )
        #expect(values.allSatisfy { $0.hasPrefix("META_API_KEY=") == false })
        #expect(values.allSatisfy { $0.hasPrefix("OPENAI_API_KEY=") == false })
        #expect(values.allSatisfy { $0.hasPrefix("GH_TOKEN=") == false })
        // The only ANTHROPIC_API_KEY spelling is the public placeholder.
        let anthropic = values.filter { $0.hasPrefix("ANTHROPIC_API_KEY=") }
        #expect(anthropic == ["ANTHROPIC_API_KEY=\(AgentHomeStaging.anthropicGatewayPlaceholder)"])
        // No live value appears under any name.
        for entry in values {
            #expect(entry.contains(liveMeta) == false)
            #expect(entry.contains(liveAnthropic) == false)
        }
    }
}

@Test func optedInKeysStillRequireSaneValues() {
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .inherit,
        agentBin: "/opt/rv/bin/rv-agent-bin",
        hostEnvironment: [
            "META_API_KEY": "has\nnewline",
            "ANTHROPIC_API_KEY": String(repeating: "x", count: 40_000),
        ],
        credentialDelivery: .legacyOptIn
    )
    #expect(values.allSatisfy { $0.hasPrefix("META_API_KEY=") == false })
    #expect(values.contains("ANTHROPIC_API_KEY=rv-cage-gateway-placeholder"))
}

@Test func insaneGatewayValuesStayStripped() {
    // No second, weaker check can smuggle through a gateway value the
    // projection refused.
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        agentBin: "/opt/rv/bin/rv-agent-bin",
        hostEnvironment: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:10100\ninjected"],
        credentialDelivery: .legacyOptIn
    )
    #expect(values.allSatisfy { $0.hasPrefix("ANTHROPIC_BASE_URL=") == false })
}

@Test func keychainCannotClaimRuntimeManagedNames() {
    // Keychain entries are operator opt-in, but runtime-managed names stay
    // runtime-owned: first-wins covers the present ones (PATH, HOME, ...)
    // and the managed-name check covers the absent ones (OLDPWD, SHLVL, _).
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .inherit, hostEnvironment: [:],
        keychain: [
            ("PATH", "smuggled"),
            ("HOME", "smuggled"),
            ("TMPDIR", "smuggled"),
            ("OLDPWD", "smuggled"),
            ("SHLVL", "smuggled"),
            ("_", "smuggled"),
            ("RV_SYNTH_KEY", "synthetic-secret"),
        ]
    )
    #expect(values.contains("PATH=/usr/bin:/bin"))
    #expect(values.contains("HOME=/tmp/ws"))
    #expect(values.allSatisfy { $0 != "PATH=smuggled" })
    #expect(values.allSatisfy { $0 != "HOME=smuggled" })
    #expect(values.allSatisfy { $0 != "TMPDIR=smuggled" })
    #expect(values.allSatisfy { $0.hasPrefix("OLDPWD=") == false })
    #expect(values.allSatisfy { $0.hasPrefix("SHLVL=") == false })
    #expect(values.allSatisfy { $0 != "_=smuggled" })
    #expect(values.contains("RV_SYNTH_KEY=synthetic-secret"))
}

@Test func keychainRefusesInvalidNamesAndInsaneValues() {
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .inherit, hostEnvironment: [:],
        keychain: [
            ("not an env", "synthetic-secret"),
            ("", "synthetic-secret"),
            ("9LEADING_DIGIT", "synthetic-secret"),
            ("RV_BAD_VALUE", "has\nnewline"),
            ("RV_BAD_NUL", "has\0nul"),
            ("RV_TOO_BIG", String(repeating: "x", count: 9_000)),
            ("RV_SYNTH_OK", "synthetic-secret"),
        ]
    )
    #expect(values.allSatisfy { $0.hasPrefix("not an env=") == false })
    #expect(values.allSatisfy { $0.hasPrefix("9LEADING_DIGIT=") == false })
    #expect(values.allSatisfy { $0.hasPrefix("RV_BAD_VALUE=") == false })
    #expect(values.allSatisfy { $0.hasPrefix("RV_BAD_NUL=") == false })
    #expect(values.allSatisfy { $0.hasPrefix("RV_TOO_BIG=") == false })
    #expect(values.contains("RV_SYNTH_OK=synthetic-secret"))
}
#endif
