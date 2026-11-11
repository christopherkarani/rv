import Testing
import RVDomain
@testable import RVEngine

@Suite("Secret Service keyring guard")
struct SecretServiceGuardTests {
    static let touching: [String] = [
        "secret-tool lookup service rv.secrets account OPENAI_API_KEY",
        "secret-tool search --all service rv.secrets",
        "/usr/bin/secret-tool lookup service rv.secrets account GH_TOKEN",
        "secret-tool store --label=x service rv.secrets account GH_TOKEN",
        "secret-tool clear service rv.secrets account GH_TOKEN",
        "SECRET_TOOL=1 secret-tool lookup service x account y",
        "env secret-tool lookup service x account y",
        "sudo -u me secret-tool lookup service x account y",
        "bash -c 'secret-tool lookup service rv.secrets account K'",
        "ls; secret-tool lookup service rv.secrets account K | base64",
        "'secret-tool' lookup service rv.secrets account K",
        "s\\ecret-tool lookup service rv.secrets account K",
        "$T lookup service rv.secrets account K",
        "gdbus call --session --dest org.freedesktop.secrets --object-path /org/freedesktop/secrets "
            + "--method org.freedesktop.Secret.Service.SearchItems \"{'service': <'rv.secrets'>}\"",
        "busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service SearchItems",
        "dbus-send --session --print-reply --dest=org.freedesktop.secrets /org/freedesktop/secrets x",
        "python3 -c 'import dbus; dbus.SessionBus().get_object(\"org.freedesktop.secrets\", \"/\")'",
        "gdbus call --session --dest 'org.freedesktop.'\"secrets\" --object-path / --method x",
    ]

    static let harmless: [String] = [
        "ls -la",
        "git status",
        "echo secret tool",
        "grep -r secret-tool src/",
        "man secret-tool",
        "apt-get install libsecret-tools",
        "cat README.md",
        "$EDITOR notes.txt",
        "busctl --user list",
    ]

    @Test(arguments: touching)
    func touchesTheKeyring(_ command: String) {
        #expect(SecretServiceGuard.touchesSecretService(ShellCommand(rawValue: command)), "\(command)")
    }

    @Test(arguments: harmless)
    func leavesOtherCommandsAlone(_ command: String) {
        #expect(SecretServiceGuard.touchesSecretService(ShellCommand(rawValue: command)) == false, "\(command)")
    }

    @Test func foldDeniesAnAllowedKeyringReadAsCoreSecrets() {
        let command = "secret-tool lookup service rv.secrets account OPENAI_API_KEY"
        let allowed = EvaluationResult(outcome: .plain, matchingView: MatchingView(command))
        let folded = SecretPathDecider.dayOne.fold(allowed, command: ShellCommand(rawValue: command))
        guard case .deny(let deny, _) = folded.outcome else {
            Issue.record("expected a deny, got \(folded.outcome)")
            return
        }
        #expect(deny.ruleID == RuleID(pack: .coreSecrets, pattern: "secret-service"))
        // A disabled secret-path catalog disables this rule with it.
        let off = SecretPathDecider(catalog: .empty).fold(allowed, command: ShellCommand(rawValue: command))
        #expect(off == allowed)
    }
}
