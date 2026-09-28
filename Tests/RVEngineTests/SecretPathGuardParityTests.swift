import Foundation
import Testing
import RVDomain
@testable import RVEngine

/// Committed regression net for the T3b3 old-vs-new SecretPathGuard differential.
///
/// The migration commit verified the rewrite against the legacy
/// `tokenizeCommand`/`parseFlag` implementation over ~11k generated cases;
/// this file commits the generator so that verification keeps running. The
/// corpus is a deterministic cross-product of heads, flag fragments, and
/// operands (plus newline/edge specials). Outcomes fold into an FNV-1a digest
/// asserted below, and a spread of sentinel rows pins exact outcomes for
/// debuggability. Both the digest and the sentinels were cross-checked
/// against the base-branch implementation over the full corpus.
///
/// Debugging: set `RV_DUMP_PARITY=/path/to/file` to write one
/// `command\tincludeMetadata\truleID\tmatchedText` line per case instead of
/// asserting (used for the old-vs-new diff).
struct SecretPathGuardParityTests {
    static let heads = ["cat", "grep", "rg", "find", "echo", "ls"]

    static let slotA = [
        "", "-e", "-f", "-i", "-r", "--", "-", "-name", "-iname", "-path",
        "--regexp=x", "--file=x",
    ]

    static let slotB = [
        "", "-e pat", "--", "pat", "-f", "-type f", "!", "(", "-e=x",
        "--files", "-n", "-H",
    ]

    static let slotC = [
        "", ".env", "pat", "~/.ssh", ".env.local", "x=y", "if=.env",
        "-name=.env", ".gitignore", "--opt=.env", ";", ".env pat",
    ]

    static let specials = [
        "",
        "   ",
        "grep \n.env",
        "\n.env",
        "cat .env\ncat .env",
        "grep -e -- .env",
        "grep -f -- .env",
        "grep -- pat .env",
        "grep -e=",
        "grep --opt=",
        "grep -e=.env",
        "grep --file=.env",
        "grep --regexp=.env",
        "grep --files=.env",
        "grep -ef .env",
        "grep -fe .env",
        "grep -1 .env",
        "grep - .env",
        "find . -name .env",
        "find . -iname .env",
        "find . -path .env",
        "find .env ! -name x",
        "find .env ( -name x )",
        "find . -name=x .env",
        "find . -iname=x .env",
        "find . -path=x .env",
        "find . -name",
        "find . -name -path",
        "dd if=.env of=/tmp/x",
        "dd of=.env",
        "cat x=",
        "cat =x",
        "cat --x=.env",
        "cat -.env",
        "ECHO .env",
        "/usr/bin/printf .env",
        "test -f ~/.ssh/id_rsa",
        "stat ~/.ssh/id_rsa",
        "ls ~/.ssh",
    ]

    static func parityCommands() -> [String] {
        var commands: [String] = []
        commands.reserveCapacity(heads.count * slotA.count * slotB.count * slotC.count + specials.count)
        for head in heads {
            for a in slotA {
                for b in slotB {
                    for c in slotC {
                        let fragments = [head, a, b, c].filter { !$0.isEmpty }
                        commands.append(fragments.joined(separator: " "))
                    }
                }
            }
        }
        commands.append(contentsOf: specials)
        return commands
    }

    /// FNV-1a 64 over the per-case outcomes. Dependency-free on purpose.
    static func digest(_ outcomes: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for outcome in outcomes {
            for byte in outcome.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 0xFF
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    static func outcome(
        for command: String,
        includeMetadata: Bool,
        catalog: SecretPathCatalog
    ) -> String {
        let hit = SecretPathGuard.firstHit(
            in: MatchingView(command),
            catalog: catalog,
            includeMetadata: includeMetadata
        )
        return "\(hit?.ruleID.rawValue ?? "-")\t\(hit?.matchedText ?? "-")"
    }

    // Verified identical on the base-branch implementation over the full corpus.
    static let expectedDigest = "1d95bb532764198e"
    static let expectedCount = 10407

    /// Every 647th command's exact outcome (includeMetadata: false), generated
    /// from the corpus and cross-checked against the base implementation.
    static let sentinels: [(command: String, ruleID: String?, matchedText: String?)] = [
        ("cat", nil, nil),  // #0
        ("cat -r -type f .env pat", "core.secrets:env", ".env"),  // #647
        ("cat -iname -H ;", nil, nil),  // #1294
        ("grep -e -type f --opt=.env", "core.secrets:env", ".env"),  // #1941
        ("grep -- -H .gitignore", nil, nil),  // #2588
        ("grep --regexp=x -type f -name=.env", "core.secrets:env", ".env"),  // #3235
        ("rg -f -H if=.env", nil, nil),  // #3882
        ("rg -name -type f x=y", nil, nil),  // #4529
        ("rg --file=x -H .env.local", "core.secrets:env-variant", ".env.local"),  // #5176
        ("find -r -type f ~/.ssh", nil, nil),  // #5823
        ("find -iname -H pat", nil, nil),  // #6470
        ("echo -e -type f .env", nil, nil),  // #7117
        ("echo -- -H", nil, nil),  // #7764
        ("echo --regexp=x -f .env pat", nil, nil),  // #8411
        ("ls -f -n ;", nil, nil),  // #9058
        ("ls -name -f --opt=.env", nil, nil),  // #9705
        ("ls --file=x -n .gitignore", nil, nil),  // #10352
    ]

    @Test func secretPathGuard_parityCorpusMatchesCommittedDigest() {
        let catalog = SecretPathCatalog.dayOne
        let commands = Self.parityCommands()
        if let dumpPath = ProcessInfo.processInfo.environment["RV_DUMP_PARITY"] {
            var lines: [String] = []
            lines.reserveCapacity(commands.count * 2)
            for command in commands {
                for includeMetadata in [false, true] {
                    let flat = command
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\n", with: "\\n")
                        .replacingOccurrences(of: "\t", with: "\\t")
                    lines.append(
                        "\(flat)\t\(includeMetadata)\t\(Self.outcome(for: command, includeMetadata: includeMetadata, catalog: catalog))"
                    )
                }
            }
            try! lines.joined(separator: "\n").write(
                toFile: dumpPath,
                atomically: true,
                encoding: .utf8
            )
            return
        }
        #expect(commands.count == Self.expectedCount, "corpus size changed: \(commands.count)")
        var outcomes: [String] = []
        outcomes.reserveCapacity(commands.count * 2)
        for command in commands {
            outcomes.append(Self.outcome(for: command, includeMetadata: false, catalog: catalog))
            outcomes.append(Self.outcome(for: command, includeMetadata: true, catalog: catalog))
        }
        let actual = Self.digest(outcomes)
        #expect(actual == Self.expectedDigest, "parity digest mismatch: got \(actual)")
    }

    @Test func secretPathGuard_paritySentinels() {
        let catalog = SecretPathCatalog.dayOne
        for sentinel in Self.sentinels {
            let hit = SecretPathGuard.firstHit(
                in: MatchingView(sentinel.command),
                catalog: catalog
            )
            #expect(
                hit?.ruleID.rawValue == sentinel.ruleID,
                "\(sentinel.command.debugDescription) ruleID"
            )
            #expect(
                hit?.matchedText == sentinel.matchedText,
                "\(sentinel.command.debugDescription) matchedText"
            )
        }
    }
}
