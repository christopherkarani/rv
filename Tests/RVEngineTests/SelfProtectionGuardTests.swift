import Testing
import RVDomain
@testable import RVEngine

@Suite("rv self-protection guard")
struct SelfProtectionGuardTests {
    static let weakening: [String] = [
        "rv packs disable core.filesystem",
        "rv uninstall",
        "rv uninstall --yes",
        "rv safety normal",
        "rv allowlist add core.git:reset-hard",
        "rv allowlist add-command 'git reset --hard'",
        "rv allow-once",
        "rv allow-once redeem 123456",
        "rv allow-once mint",
        "rv policy apply policy.toml",
        "rv policy draft --save 'allow rm'",
        "rv egress approve 1",
        "rv mcp approve 1",
        "rv mcp trust",
        "rv secrets hook uninstall",
        "rv managed sign policy.json",
        "~/.local/bin/rv packs disable core.git",
        "sudo rv uninstall",
        "env RV_X=1 rv safety normal",
        "ls && rv packs disable core.git",
        "bash -c 'rv uninstall'",
    ]

    static let harmless: [String] = [
        "rv test 'ls'",
        "rv doctor",
        "rv packs list",
        "rv packs enable database.postgresql",
        "rv safety",
        "rv safety strict",
        "rv policy show",
        "rv allowlist list",
        "rv allow-once list",
        "rv explain 'rm -rf /'",
        "rv blocks",
        "echo rv uninstall",
        "git commit -m 'rv uninstall docs'",
        "ls rv",
    ]

    @Test("agent-issued rv commands that weaken policy are flagged", arguments: weakening)
    func weakeningFlagged(command: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)), "\(command)")
    }

    @Test("read-only and strengthening rv commands are not", arguments: harmless)
    func harmlessPass(command: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)) == false, "\(command)")
    }
}
