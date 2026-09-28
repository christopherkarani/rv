#if os(macOS)
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

@Test func unselectedRuntimeGetsNoHostEnvironmentOrAgentPath() {
    let host = ["META_API_KEY": "secret", "ANTHROPIC_BASE_URL": "http://localhost:10000"]
    for io in [IsolatedIO.inherit, .pseudoTerminal(rows: 24, columns: 80)] {
        let values = containedRuntimeEnvironment(workspace: "/tmp/ws", io: io, hostEnvironment: host)
        #expect(values.contains("PATH=/usr/bin:/bin"))
        #expect(values.contains("HOME=/tmp/ws"))
        #expect(values.contains("TMPDIR=/tmp/ws"))
        #expect(values.allSatisfy { !$0.hasPrefix("META_API_KEY=") })
        #expect(values.allSatisfy { !$0.hasPrefix("ANTHROPIC_BASE_URL=") })
    }
}

@Test func selectedManifestIsIdenticalForOneShotAndTerminalResources() {
    let profile = RuntimeResourceProfile(
        id: "profile-a", projects: ["/tmp/project"],
        environment: [
            .init(name: "SELECTED_KEY", hostVariable: "HOST_KEY"),
            .init(name: "TOOL_NO_UPDATE", literalValue: "1"),
        ]
    )
    let resources = RuntimeResourceManifest(profile)
    let host = ["HOST_KEY": "synthetic", "OTHER_KEY": "hidden"]
    for io in [IsolatedIO.inherit, .pseudoTerminal(rows: 24, columns: 80)] {
        let values = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: io, resources: resources, hostEnvironment: host
        )
        #expect(values.contains("HOME=\(resources.privateHome)"))
        #expect(values.contains("TMPDIR=\(resources.tmp)"))
        #expect(values.contains("PATH=\(resources.bin):/usr/bin:/bin"))
        #expect(values.contains("SELECTED_KEY=synthetic"))
        #expect(values.contains("TOOL_NO_UPDATE=1"))
        #expect(values.allSatisfy { !$0.hasPrefix("OTHER_KEY=") })
    }
}

@Test func keychainValuesLandInEnvironmentForAnyIO() {
    for io in [IsolatedIO.inherit, .pseudoTerminal(rows: 24, columns: 80)] {
        let values = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: io, hostEnvironment: [:],
            keychain: [("RV_SYNTH_KEY", "synthetic-secret")]
        )
        #expect(values.contains("RV_SYNTH_KEY=synthetic-secret"))
    }
}

@Test func terminalEnvironmentKeepsColorAndBoundedLoopbackProxy() {
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        egressProxyPort: 39321, hostEnvironment: [:]
    )
    #expect(values.contains("TERM=xterm-256color"))
    #expect(values.contains("CLICOLOR=1"))
    #expect(values.contains("HTTPS_PROXY=http://127.0.0.1:39321"))
    #expect(values.contains("NO_PROXY=localhost,127.0.0.1"))
    #expect(values.allSatisfy { !$0.hasPrefix("PS1=") })
    for bad in [0, -1, 70_000] {
        let omitted = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
            egressProxyPort: bad, hostEnvironment: [:]
        )
        #expect(omitted.allSatisfy { !$0.hasPrefix("HTTPS_PROXY=") })
    }
}
#endif
