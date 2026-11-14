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
        "rv policy rollback 1 --save",
        "rv policy rollback --save r1",
        "rv policy rollback --repo 2 --save --json",
        "rv policy rollback 1 $S",
        "rv policy rollback $R --save",
        "rv-cli policy rollback 1 --save",
        "bash -c 'rv policy rollback 1 --save'",
        "rv egress approve 1",
        "rv mcp approve 1",
        "rv mcp trust",
        "rv secrets hook uninstall",
        "rv secrets set ACME_KEY --gateway https://api.acme.com --base-url-env ACME_BASE_URL",
        "printf %s x | rv secrets set GH_TOKEN --environment",
        "rv secrets remove OPENAI_API_KEY",
        "rv secrets oauth-reset API",
        "rv secrets import --varlock .env.schema --resource-profile main",
        "rv managed sign policy.json",
        "~/.local/bin/rv packs disable core.git",
        "sudo rv uninstall",
        "env RV_X=1 rv safety normal",
        "ls && rv packs disable core.git",
        "bash -c 'rv uninstall'",
        "rv-cli packs disable core.git",
        "~/.local/bin/rv-cli uninstall",
        "rv-cli allow-once redeem 123456",
        // `rv host mode <host> <mode>`: anything but `block` sheds oversight.
        "rv host mode claude off",
        "rv host mode claude observe",
        "rv host mode claude",
        "rv host mode",
        "rv host mode claude loud",
        "rv host mode claude block off",
        "rv host mode claude $MODE",
        "rv host mode $HOST off",
        "rv host $SUB claude off",
        "rv host --json mode claude off",
        "rv host mode --json claude off",
        "bash -c 'rv host mode cursor off'",
        "rv-cli host mode codex observe",
    ]

    static let harmless: [String] = [
        "rv test 'ls'",
        "rv doctor",
        "rv packs list",
        "rv packs enable database.postgresql",
        "rv safety",
        "rv safety strict",
        "rv policy show",
        "rv policy show --revision 2",
        "rv policy rollback 1",
        "rv policy rollback r2 --repo --json",
        "rv allowlist list",
        "rv allow-once list",
        "rv explain 'rm -rf /'",
        "rv blocks",
        "echo rv uninstall",
        "git commit -m 'rv uninstall docs'",
        "ls rv",
        "rv-cli packs list",
        "rv-cli doctor",
        "rv secrets",
        "rv secrets list",
        "rv secrets check",
        "rv secrets describe",
        "rv secrets scan .",
        "rv secrets import --varlock .env.schema --dry-run",
        "rv secrets hook install",
        "rv host",
        "rv host list",
        "rv host list --json",
        "rv host mode claude block",
        "rv host mode claude block --json",
        "rv host mode --json claude block",
        "rv host mode $HOST block",
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
