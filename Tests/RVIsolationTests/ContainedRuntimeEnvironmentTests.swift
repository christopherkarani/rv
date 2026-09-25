#if os(macOS)
import Foundation
import Testing
@testable import RVIsolation

@Test func pseudoTerminalEnvironmentAdvertisesColorOutput() {
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80), hostEnvironment: [:]
    )
    #expect(values.contains("TERM=xterm-256color"))
    #expect(values.contains("CLICOLOR=1"))
    // zsh ignores an inherited PS1, so none is set; the prompt stays the
    // zsh default unless the user creates a workspace-local .zshrc.
    #expect(values.allSatisfy { $0.hasPrefix("PS1=") == false })
    #expect(values.contains("PATH=/usr/bin:/bin"))
    #expect(values.contains("HOME=/tmp/ws"))
    #expect(values.contains("TMPDIR=/tmp/ws/.rv-cage/tmp"))
}

@Test func nonTerminalEnvironmentStaysMinimal() {
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws",
        io: .inherit,
        agentBin: "/opt/rv/bin/rv-agent-bin",
        egressProxyPort: 39321,
        hostEnvironment: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:10100"]
    )
    #expect(values.contains("TERM=xterm-256color") == false)
    #expect(values.contains("CLICOLOR=1") == false)
    #expect(values.allSatisfy { $0.hasPrefix("PS1=") == false })
    #expect(values.contains("PATH=/usr/bin:/bin"))
    #expect(values.contains("TMPDIR=/tmp/ws"))
    #expect(values.allSatisfy { $0.hasPrefix("HTTPS_PROXY=") == false })
    #expect(values.allSatisfy { $0.hasPrefix("ANTHROPIC_BASE_URL=") == false })
}

@Test func terminalPATHPrefersInstalledAgentBin() {
    let plain = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        agentBin: nil, hostEnvironment: [:]
    )
    #expect(plain.contains("PATH=/usr/bin:/bin"))
    let agent = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        agentBin: "/opt/rv/bin/rv-agent-bin", hostEnvironment: [:]
    )
    #expect(agent.contains("PATH=/opt/rv/bin/rv-agent-bin:/usr/bin:/bin"))
    // The cage cannot manage host services or rewrite installs.
    #expect(agent.contains("OCX_SHIM_BYPASS=1"))
    #expect(agent.contains("MUSE_NO_AUTO_UPDATE=1"))
    #expect(agent.contains("DISABLE_AUTOUPDATER=1"))
    #expect(plain.allSatisfy { $0.hasPrefix("OCX_SHIM_BYPASS=") == false })
    let oneShot = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .inherit, agentBin: "/opt/rv/bin/rv-agent-bin"
    )
    #expect(oneShot.contains("PATH=/usr/bin:/bin"))
}
@Test func terminalEnvironmentExposesEgressProxy() {
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        egressProxyPort: 39321, hostEnvironment: [:]
    )
    #expect(values.contains("HTTPS_PROXY=http://127.0.0.1:39321"))
    #expect(values.contains("HTTP_PROXY=http://127.0.0.1:39321"))
    #expect(values.contains("https_proxy=http://127.0.0.1:39321"))
    #expect(values.contains("http_proxy=http://127.0.0.1:39321"))
    #expect(values.contains("NO_PROXY=localhost,127.0.0.1"))
    #expect(values.contains("no_proxy=localhost,127.0.0.1"))
    for bad in [0, -1, 70_000] {
        let omitted = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
            egressProxyPort: bad, hostEnvironment: [:]
        )
        #expect(omitted.allSatisfy { $0.hasPrefix("HTTPS_PROXY=") == false })
        #expect(omitted.allSatisfy { $0.hasPrefix("NO_PROXY=") == false })
        #expect(omitted.allSatisfy { $0.hasPrefix("no_proxy=") == false })
    }
    let missing = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        hostEnvironment: [:]
    )
    #expect(missing.allSatisfy { $0.hasPrefix("HTTPS_PROXY=") == false })
    #expect(missing.allSatisfy { $0.hasPrefix("NO_PROXY=") == false })
}

@Test func terminalEnvironmentPassesGatewayThrough() {
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        agentBin: "/opt/rv/bin/rv-agent-bin",
        hostEnvironment: [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:10100",
            "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
            "ANTHROPIC_API_KEY": "host-key-value",
        ]
    )
    #expect(values.contains("ANTHROPIC_BASE_URL=http://127.0.0.1:10100"))
    #expect(values.contains("CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1"))
    #expect(values.contains("ANTHROPIC_API_KEY=host-key-value"))
    #expect(values.allSatisfy { $0.hasPrefix("CLAUDE_CODE_AUTO_COMPACT_WINDOW=") == false })
}

@Test func terminalEnvironmentKeyPolicy() {
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        agentBin: "/opt/rv/bin/rv-agent-bin",
        hostEnvironment: [
            "META_API_KEY": "keychain-captive",
            "OPENAI_API_KEY": "must-not-pass",
        ]
    )
    #expect(values.contains("META_API_KEY=keychain-captive"))
    #expect(values.allSatisfy { $0.hasPrefix("OPENAI_API_KEY=") == false })
    // No host key: the gateway placeholder stands in, never empty/absent.
    #expect(values.contains("ANTHROPIC_API_KEY=rv-cage-gateway-placeholder"))
    // A host key wins over the placeholder.
    let explicit = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        agentBin: "/opt/rv/bin/rv-agent-bin",
        hostEnvironment: ["ANTHROPIC_API_KEY": "host-key-value"]
    )
    #expect(explicit.contains("ANTHROPIC_API_KEY=host-key-value"))
    #expect(explicit.allSatisfy { $0 != "ANTHROPIC_API_KEY=rv-cage-gateway-placeholder" })
    // One-shot stays minimal: no keys, no placeholder.
    let oneShot = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .inherit,
        agentBin: "/opt/rv/bin/rv-agent-bin",
        hostEnvironment: ["META_API_KEY": "x", "ANTHROPIC_API_KEY": "x"]
    )
    #expect(oneShot.allSatisfy { $0.hasPrefix("META_API_KEY=") == false })
    #expect(oneShot.allSatisfy { $0.hasPrefix("ANTHROPIC_API_KEY=") == false })
}
#endif
