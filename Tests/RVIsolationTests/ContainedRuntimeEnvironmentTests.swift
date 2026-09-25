import Foundation
import Testing
@testable import RVIsolation

@Test func pseudoTerminalEnvironmentAdvertisesColorOutput() {
    let values = containedRuntimeEnvironment(workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80))
    #expect(values.contains("TERM=xterm-256color"))
    #expect(values.contains("CLICOLOR=1"))
    // zsh ignores an inherited PS1, so none is set; the prompt stays the
    // zsh default unless the user creates a workspace-local .zshrc.
    #expect(values.allSatisfy { $0.hasPrefix("PS1=") == false })
    #expect(values.contains("PATH=/usr/bin:/bin"))
    #expect(values.contains("HOME=/tmp/ws"))
    #expect(values.contains("TMPDIR=/tmp/ws"))
}

@Test func nonTerminalEnvironmentStaysMinimal() {
    let values = containedRuntimeEnvironment(workspace: "/tmp/ws", io: .inherit)
    #expect(values.contains("TERM=xterm-256color") == false)
    #expect(values.contains("CLICOLOR=1") == false)
    #expect(values.allSatisfy { $0.hasPrefix("PS1=") == false })
    #expect(values.contains("PATH=/usr/bin:/bin"))
}

@Test func terminalPATHPrefersInstalledAgentShims() {
    let plain = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80), agentShims: nil
    )
    #expect(plain.contains("PATH=/usr/bin:/bin"))
    let shimmed = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80), agentShims: "/opt/rv/bin/rv-agent-shims"
    )
    #expect(shimmed.contains("PATH=/opt/rv/bin/rv-agent-shims:/usr/bin:/bin"))
    let oneShot = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .inherit, agentShims: "/opt/rv/bin/rv-agent-shims"
    )
    #expect(oneShot.contains("PATH=/usr/bin:/bin"))
}
