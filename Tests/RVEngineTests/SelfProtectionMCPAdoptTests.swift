import RVDomain
import Testing
@testable import RVEngine

/// `rv mcp add` rewrites agent host configs and moves keys; `rv mcp remove`
/// and `rv mcp setup --undo` take servers back out from under rv. The owner
/// runs them, never an agent. `--preview` only reads.
@Suite("rv self-protection guard: MCP adoption")
struct SelfProtectionMCPAdoptTests {
    @Test(arguments: [
        "rv mcp add",
        "rv mcp add cursor",
        "rv mcp add claude --server linear",
        "rv mcp add --project . cursor",
        "rv mcp add $HOST",
        "rv mcp remove",
        "rv mcp remove cursor",
        "rv-cli mcp remove codex",
        "~/.local/bin/rv mcp add cursor",
        "/usr/local/bin/rv mcp remove",
        "bash -c 'rv mcp add'",
        "rv mcp setup --host cursor --undo",
        "rv mcp setup --host $H",
        "rv mcp $SUB cursor",
    ])
    func ownerOnly(_ command: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)), "\(command)")
    }

    @Test(arguments: [
        "rv mcp add --preview",
        "rv mcp add cursor --preview",
        "rv mcp remove --preview",
        "rv mcp add --help",
        "rv mcp remove --help",
        "rv mcp list",
        "rv mcp check",
        "rv mcp setup --host cursor",
        "rv mcp import --host cursor --dry-run",
    ])
    func agentsMayRead(_ command: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)) == false, "\(command)")
    }

    /// `$C mcp add` is how an agent host CLI adds a server; the MCP host
    /// config guard denies it, so self-protection leaves it to that deny
    /// (`MCPHostConfigCorpusTests`) instead of flooring it first.
    @Test func aDynamicHeadIsLeftToTheHostConfigGuard() {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: "C=claude; $C mcp add evil x")) == false)
    }
}
