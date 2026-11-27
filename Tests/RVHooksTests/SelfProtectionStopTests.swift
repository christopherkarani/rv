import Foundation
import RVDomain
@testable import RVHooks
import Testing

/// B2 / S3: self-protection says its name, names the human's command, and
/// points at that verb's help page.
struct SelfProtectionStopTests {
    private static let chris = StopVoice(owner: OwnerName(gecos: "Chris Karani"))

    private static func text(_ command: String, voice: StopVoice = chris) -> String? {
        hostDenyText(
            from: EvaluationResult(outcome: .indeterminate(.selfProtection)),
            command: ShellCommand(rawValue: command),
            voice: voice)
    }

    @Test func uninstall_saysRvProtectsItself() {
        #expect(Self.text("rv uninstall") == """
            ✕ rv protects itself   rv uninstall (rv.indeterminate/selfProtection)
            why     agents can't change rv's own settings
            safer   rv uninstall --help
            who     ask Chris to run  rv uninstall
            """)
    }

    /// S3: the secrets stop names the owner's exact command and lets the
    /// agent read its help.
    @Test func secretsSet_namesTheHumansCommand() {
        #expect(Self.text("rv secrets set STRIPE_KEY --gateway https://api.stripe.com") == """
            ✕ rv protects itself   rv secrets set STRIPE_KEY --gateway https://api.stripe.com (rv.indeterminate/selfProtection)
            why     agents can't change rv's own settings
            safer   rv secrets set --help
            who     ask Chris to run  rv secrets set STRIPE_KEY --gateway https://api.stripe.com
            """)
    }

    /// A pipe, a script or anything that is not one plain rv invocation is
    /// not handed to the owner to paste: they run it in their own terminal.
    @Test(arguments: [
        "echo uninstall | xargs rv",
        "sh -c 'rv uninstall'",
        "rv host mode claude $MODE",
        "rv uninstall; ls",
        "RV=1 rv uninstall",
    ])
    func notAPlainInvocation_asksForTheirOwnTerminal(_ command: String) throws {
        let text = try #require(Self.text(command))
        #expect(text.hasPrefix("✕ rv protects itself   "))
        #expect(text.hasSuffix("who     ask Chris to run it in their own terminal"))
        #expect(text.contains("safer") == false)
    }

    @Test func noOwnerName_saysYourUser() throws {
        let text = try #require(Self.text("rv safety normal", voice: .plain))
        #expect(text.hasSuffix("who     ask your user to run  rv safety normal"))
    }

    /// Acceptance: one instruction, the rule id, never an unlock or
    /// allow-once for the agent itself.
    @Test(arguments: ["rv uninstall", "rv allowlist add 'git push'", "rv allow-once abc123", "rv packs disable core.git"])
    func everySelfProtectionStop_hasOneWhoAndNoWayPast(_ command: String) throws {
        let text = try #require(Self.text(command))
        #expect(text.contains("(rv.indeterminate/selfProtection)"))
        #expect(text.components(separatedBy: "\nwho ").count == 2)
        let safer = text.split(separator: "\n").first { $0.hasPrefix("safer") }
        #expect(safer.map { $0.contains("allow-once") || $0.contains("unlock") } != true)
    }

    @Test func helpCommand_isTheFormSelfProtectionLetsThrough() {
        #expect(rvHelpCommand(["rv", "host", "mode", "claude", "observe"]) == "rv host mode --help")
        #expect(rvHelpCommand(["rv", "uninstall", "--force"]) == "rv uninstall --help")
        #expect(rvHelpCommand(["rv", "--force"]) == nil)
        #expect(rvHelpCommand(["rv", "Uninstall"]) == nil)
    }

    /// Per-codec goldens (`Fixtures/self-protection/<host>.txt`): the
    /// bytes each host gets for a self-protection stop, plain and piped.
    @Test(arguments: HookHost.allCases)
    func everyCodecWritesTheGolden(_ host: HookHost) throws {
        let codec = productionHostCodec(host)
        let stops = ["rv secrets set STRIPE_KEY", "echo uninstall | xargs rv"].map { command in
            (name: command, wire: hookWire(
                from: EvaluationResult(outcome: .indeterminate(.selfProtection)),
                command: ShellCommand(rawValue: command),
                using: codec, intent: .firstCall(verdict: .deny, unlockCode: nil), voice: StopShapeGoldenTests.voice))
        }
        let actual = StopShapeGoldenTests.render(stops)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/self-protection/\(host.rawValue).txt")
        guard let golden = try? String(contentsOf: url, encoding: .utf8) else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
            Issue.record("wrote a new golden for \(host); review it and run again")
            return
        }
        #expect(actual == golden, "\(host)")
        #expect(actual.contains("rv protects itself"))
    }

    /// S3: reading rv's own config dir points at the names, never the file.
    @Test func rvConfigRead_offersSecretsList() throws {
        let rule = try #require(RuleID(rawValue: "core.secrets:home-rv-config"))
        let text = hostFileDenyLine(
            path: FileToolPath(rawValue: "/Users/c/.config/rv/secrets.json"),
            deny: Deny(ruleID: rule, reason: "rv's own config holds its policy and keys."),
            voice: Self.chris)
        #expect(text.contains("\nsafer   rv secrets list\n"))
    }
}
