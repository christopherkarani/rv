import Foundation
import Testing
@testable import RVService

/// Credentials in the command-line forms they travel in leave rvd hidden;
/// the shape of the command stays readable.
struct CommandLineRedactionTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let command: String
        let shown: String
        let secret: String
        var testDescription: String { command }
    }

    static let credentials: [Case] = [
        Case(command: "curl -u bob:hunter2 https://api.example.com",
             shown: "curl -u bob:[redacted] https://api.example.com", secret: "hunter2"),
        Case(command: "curl --user=bob:hunter2 https://api.example.com",
             shown: "curl --user=bob:[redacted] https://api.example.com", secret: "hunter2"),
        Case(command: "git clone https://bob:hunter2@git.example.com/repo.git",
             shown: "git clone https://bob:[redacted]@git.example.com/repo.git", secret: "hunter2"),
        Case(command: "git push https://bob:p@ss@git.example.com/r main",
             shown: "git push https://bob:[redacted]@git.example.com/r main", secret: "p@ss"),
        Case(command: "mysql -phunter2 -u root shop",
             shown: "mysql -p[redacted] -u root shop", secret: "hunter2"),
        Case(command: "cd /srv && mysqldump -p'hunter2' shop",
             shown: "cd /srv && mysqldump -p[redacted]' shop", secret: "hunter2"),
        Case(command: "pg_dump --password hunter2 shop",
             shown: "pg_dump --password [redacted] shop", secret: "hunter2"),
        Case(command: "deploy --api-key abc123 --env prod",
             shown: "deploy --api-key [redacted] --env prod", secret: "abc123"),
        Case(command: "curl -H 'X-Api-Key: abc123' https://api.example.com",
             shown: "curl -H 'X-Api-Key: [redacted]' https://api.example.com", secret: "abc123"),
        Case(command: "curl -H 'X-Api-Key:abc123' https://api.example.com",
             shown: "curl -H 'X-Api-Key:[redacted]' https://api.example.com", secret: "abc123"),
        Case(command: #"curl -H "Authorization: Basic Ym9iOmh1bnRlcjI=" https://api.example.com"#,
             shown: #"curl -H "Authorization: [redacted] [redacted]" https://api.example.com"#,
             secret: "Ym9iOmh1bnRlcjI="),
        Case(command: "curl --header=X-Auth-Token:abc123 https://api.example.com",
             shown: "curl --header=X-Auth-Token:[redacted] https://api.example.com", secret: "abc123"),
        // The program anywhere earlier in the segment, not only first.
        Case(command: "docker exec db mysql -phunter2 shop",
             shown: "docker exec db mysql -p[redacted] shop", secret: "hunter2"),
        Case(command: "kubectl exec pod -- mysql -phunter2 shop",
             shown: "kubectl exec pod -- mysql -p[redacted] shop", secret: "hunter2"),
        Case(command: #"sh -c "mysql -phunter2 shop""#,
             shown: #"sh -c "mysql -p[redacted] shop""#, secret: "hunter2"),
        Case(command: "sudo -u root mysql -phunter2 shop",
             shown: "sudo -u root mysql -p[redacted] shop", secret: "hunter2"),
        Case(command: "curl -ubob:hunter2 https://api.example.com",
             shown: "curl -ubob:[redacted] https://api.example.com", secret: "hunter2"),
        Case(command: "sshpass -p hunter2 ssh host.example",
             shown: "sshpass -p [redacted] ssh host.example", secret: "hunter2"),
        Case(command: "sshpass -phunter2 ssh host.example",
             shown: "sshpass -p[redacted] ssh host.example", secret: "hunter2"),
        Case(command: "redis-cli -h cache -a hunter2 get k",
             shown: "redis-cli -h cache -a [redacted] get k", secret: "hunter2"),
        Case(command: "docker login -u bob -p hunter2 registry.example",
             shown: "docker login -u bob -p [redacted] registry.example", secret: "hunter2"),
        Case(command: "gh auth login --token hunter2 --hostname h",
             shown: "gh auth login --token [redacted] --hostname h", secret: "hunter2"),
    ]

    @Test(arguments: credentials)
    func credentialFormsAreHidden(_ example: Case) {
        let shown = CommandLineRedaction.redact(example.command)
        #expect(shown == example.shown)
        #expect(shown.contains(example.secret) == false)
    }

    /// The live decision path uses it.
    @Test func liveDecisionsUseIt() {
        let shown = LiveEventRedaction.command("curl -u bob:hunter2 https://x.example", home: nil)
        #expect(shown == "curl -u bob:[redacted] https://x.example")
    }

    /// What `ReviewSanitizer` already hid stays hidden.
    @Test func assignmentsAndTokenPrefixesStayHidden() {
        let token = "ghp_" + String(repeating: "A", count: 36)
        let shown = CommandLineRedaction.redact("GITHUB_TOKEN=\(token) gh api --password=x user")
        #expect(shown.contains(token) == false)
        #expect(shown.contains("--password=x") == false)
    }

    @Test(arguments: [
        "mkdir -p build && ls -u",
        "ssh -p 22 host.example",
        "git log --author bob",
        "git add -u .",
        "curl -H 'Content-Type: application/json' https://api.example.com",
        "docker login --password-stdin -u bob",
        "git clone ssh://git@github.com/org/repo.git",
        "mysql -p shop",
        "mysql -uroot -p shop",
        "llm --max-tokens 2048 prompt",
        "vault read --secret-id abc",
        "createuser --no-password bob",
        "deploy --token --verbose",
        "docker run --name mysql -p 3306:3306 mysql:8",
        "redis-cli -h cache -p 6379 ping",
    ])
    func ordinaryCommandsAreUnchanged(_ command: String) {
        #expect(CommandLineRedaction.redact(command) == command)
    }
}
