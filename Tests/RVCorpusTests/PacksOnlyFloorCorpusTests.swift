import Testing
import RVDomain
import RVEngine

/// Packs-only floors over the shipped day-one packs.
///
/// Inline programs: the pin corpus keeps benign awk/perl/php/lua/sed rows
/// `allow`; spawn-bearing payloads carry the judge marker, which the judge
/// gate turns into indeterminate when no judge is loaded. Self-protection
/// and rv's config dir floor in `evaluate` itself, judge or not.
@Suite("Packs-only floor corpus")
struct PacksOnlyFloorCorpusTests {
    static let spawnPayloads: [String] = [
        #"perl -e 'system("rm -rf ~")'"#,
        #"awk 'BEGIN{system("rm -rf ~")}'"#,
        #"php -r 'system("rm -rf ~");'"#,
        "sed -n '1e rm -rf ~' f",
        #"node -e 'require("fs").rmSync(process.env.HOME,{recursive:true})'"#,
        #"python3 -c "from os import system; system('rm -rf ~')""#,
        #"python3 -c "print(open('/Users/x/.ssh/id_rsa').read())""#,
    ]

    @Test func pinCorpusAllowRows_carryNoJudgeMarker() throws {
        for row in try loadStressCorpus("pin-overblock-stress.json") where row.expected == "allow" {
            guard let command = row.command else { continue }
            #expect(
                InlineProgramGuard.requiresJudge(ShellCommand(rawValue: command)) == false,
                "\(row.id) must stay a packs-only allow: \(command)"
            )
        }
    }

    @Test func spawnPayloads_packAllowButCarryJudgeMarker() throws {
        let harness = try StressHarness.dayOne()
        for command in Self.spawnPayloads {
            #expect(harness.pin(command).decision == .allow, "packs alone mask \(command)")
            #expect(InlineProgramGuard.requiresJudge(ShellCommand(rawValue: command)), "\(command)")
        }
    }

    @Test func rvWeakeningCommands_areIndeterminate() throws {
        let harness = try StressHarness.dayOne()
        for command in [
            "rv packs disable core.filesystem", "rv uninstall", "rv safety normal",
            "rv-cli packs disable core.git", "~/.local/bin/rv-cli uninstall",
        ] {
            #expect(harness.pin(command).decision == .indeterminate(.selfProtection), "\(command)")
        }
        for command in ["rv packs list", "rv safety", "rv safety strict", "rv doctor"] {
            #expect(harness.pin(command).decision == .allow, "\(command)")
        }
    }

    @Test func rvConfigDirAccess_deniesAsSecret() throws {
        let harness = try StressHarness.dayOne()
        for command in [
            "cat ~/.config/rv/policy-revisions.key",
            "cat $HOME/.config/rv/policy.toml",
            "cp evil.toml ~/.config/rv/policy.toml",
        ] {
            guard case .deny(let deny) = harness.pin(command).decision else {
                Issue.record("rv config access must deny: \(command)")
                continue
            }
            #expect(deny.ruleID.rawValue == "core.secrets:home-rv-config", "\(command)")
        }
    }
}
