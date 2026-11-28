import Foundation
import RVIsolation
import Testing
@testable import RVCLI

/// The keys step's pure core: what the scan finds in shell files, the
/// environment and tool logins, what the plan offers, and the words. Every
/// value here is fake.
@Suite("Key discovery")
struct KeyDiscoveryTests {
    static let names = KnownSecretDefaults.names
    static let fakeOpenAI = "sk-fake-openai-0000aaaa1111"
    static let fakeGitHub = "ghp_fakeGitHubToken0000bbbb"

    @Test func exports_readsThePlainForms() {
        let file = """
            # export OPENAI_API_KEY=commented-out-0000
            export OPENAI_API_KEY=\(Self.fakeOpenAI)
              export ANTHROPIC_API_KEY="sk-ant-fake-0000cccc" # work
            export STRIPE_SECRET_KEY='sk_test_fake0000dddd';
            OPENAI_BASE_URL=https://example.invalid
            exported GITHUB_TOKEN=not-an-export-0000
            """
        #expect(KeyScan.exports(in: file) == [
            KeyScan.Export(name: "OPENAI_API_KEY", line: 2, literal: Self.fakeOpenAI),
            KeyScan.Export(name: "ANTHROPIC_API_KEY", line: 3, literal: "sk-ant-fake-0000cccc"),
            KeyScan.Export(name: "STRIPE_SECRET_KEY", line: 4, literal: "sk_test_fake0000dddd"),
        ])
    }

    @Test("a value the shell builds is a sighting with no value", arguments: [
        "export OPENAI_API_KEY=$(op read op://dev/openai)",
        "export OPENAI_API_KEY=\"$OPENAI_FROM_VAULT\"",
        "export OPENAI_API_KEY=`cat ~/.openai`",
        "export OPENAI_API_KEY=short",
    ])
    func exports_dynamicValueHasNoLiteral(line: String) {
        #expect(KeyScan.exports(in: line) == [KeyScan.Export(name: "OPENAI_API_KEY", line: 1, literal: nil)])
    }

    @Test("lines that are not one plain export are skipped", arguments: [
        "export OPENAI_API_KEY=\"unclosed",
        "export OPENAI_API_KEY=sk-fake-0000 && echo hi",
        "export 1BAD=sk-fake-0000aaaa",
        "exportOPENAI_API_KEY=sk-fake-0000aaaa",
    ])
    func exports_skipsWhatItCannotRead(line: String) {
        #expect(KeyScan.exports(in: line).isEmpty)
    }

    @Test func find_namesEveryPlace_andPrefersTheEnvironmentsValue() {
        let input = KeyScanInput(
            shellFiles: [
                ShellStartupFile(displayPath: "~/.zshrc", contents: "export OPENAI_API_KEY=sk-fake-from-file-0000\n"),
                ShellStartupFile(displayPath: "~/.bashrc", contents: "export UNRELATED_TOKEN=fake-0000aaaa\n"),
            ],
            environment: ["OPENAI_API_KEY": Self.fakeOpenAI, "PATH": "/usr/bin"],
            ghHosts: "github.com:\n    user: someone\n    oauth_token: \(Self.fakeGitHub)\n")
        let found = KeyScan.find(input, names: Self.names)
        #expect(found.map(\.name) == ["OPENAI_API_KEY", "GITHUB_TOKEN"])
        #expect(found[0].sightings == [.shellFile(path: "~/.zshrc", line: 1), .environment])
        #expect(found[0].value == FoundKeyValue(Self.fakeOpenAI))
        #expect(found[1].sightings == [.login("gh")])
        #expect(found[1].value == FoundKeyValue(Self.fakeGitHub))
    }

    @Test func find_takesTheLastLiteralLineInAFile() {
        let input = KeyScanInput(shellFiles: [ShellStartupFile(
            displayPath: "~/.zshrc",
            contents: "export OPENAI_API_KEY=sk-fake-old-0000\nexport OPENAI_API_KEY=sk-fake-new-0000\n")])
        let found = KeyScan.find(input, names: Self.names)
        #expect(found.first?.sightings.count == 2)
        #expect(found.first?.value == FoundKeyValue("sk-fake-new-0000"))
    }

    @Test func find_skipsStandIns_andTokenFreeLogins() {
        let input = KeyScanInput(
            environment: ["OPENAI_API_KEY": "sk-rvph_3f9a00000000", "GITHUB_TOKEN": ""],
            ghHosts: "github.com:\n    user: someone\n    git_protocol: https\n",
            vercelAuth: Data(#"{"token": ""}"#.utf8))
        #expect(KeyScan.find(input, names: Self.names).isEmpty)
    }

    @Test func ghToken_readsOnlyTheGitHubBlock() {
        let hosts = "ghe.example.com:\n    oauth_token: ghp_fakeEnterprise0000\ngithub.com:\n    oauth_token: \"\(Self.fakeGitHub)\"\n"
        #expect(KeyScan.ghToken(hosts) == Self.fakeGitHub)
        #expect(KeyScan.ghToken("ghe.example.com:\n    oauth_token: ghp_fakeEnterprise0000\n") == nil)
    }

    @Test func value_neverPrints() {
        let value = FoundKeyValue(Self.fakeOpenAI)
        let key = FoundKey(name: "OPENAI_API_KEY", sightings: [.environment], value: value)
        var dumped = ""
        dump(key, to: &dumped)
        for text in ["\(value)", String(describing: value), String(reflecting: value), "\(key)", dumped] {
            #expect(text.contains(Self.fakeOpenAI) == false)
        }
    }

    @Test func plan_offersOnlyNewNamesItCanPlace() throws {
        let found = [
            FoundKey(name: "OPENAI_API_KEY", sightings: [.shellFile(path: "~/.zshrc", line: 3)], value: FoundKeyValue(Self.fakeOpenAI)),
            FoundKey(name: "ANTHROPIC_API_KEY", sightings: [.shellFile(path: "~/.zshrc", line: 4), .environment], value: FoundKeyValue("sk-ant-fake-0000")),
            FoundKey(name: "STRIPE_SECRET_KEY", sightings: [.shellFile(path: "~/.profile", line: 1)], value: nil),
        ]
        let plan = KeyPlan.make(found, kept: ["ANTHROPIC_API_KEY"])
        #expect(plan.offers.map(\.name) == ["OPENAI_API_KEY"])
        #expect(plan.keptButExposed == [KeyExposure(name: "ANTHROPIC_API_KEY", sighting: .shellFile(path: "~/.zshrc", line: 4))])
        let unplaceable = KeyPlan.make([found[0]], kept: [], gateway: { _ in nil })
        #expect(unplaceable.isEmpty)
    }

    @Test func exposures_nameTheEnvironmentOnlyWithoutAShellLine() {
        #expect(KeyPlan.exposures(of: "X", sightings: [.environment, .login("gh")]) == [KeyExposure(name: "X", sighting: .environment)])
        #expect(KeyPlan.exposures(of: "X", sightings: [.login("gh")]).isEmpty)
    }

    @Test func gate_agentMarkersWinOverATerminal() {
        #expect(KeysGate.decide(interactive: true, agents: []) == .open)
        #expect(KeysGate.decide(interactive: false, agents: []) == .noTerminal)
        #expect(KeysGate.decide(interactive: true, agents: [.claude]) == .agent(.claude))
    }

    @Test func screen_rowsAlignAndNameTheHost() throws {
        let plan = KeyPlan.make([
            FoundKey(name: "OPENAI_API_KEY", sightings: [.environment, .shellFile(path: "~/.zshrc", line: 12)], value: FoundKeyValue(Self.fakeOpenAI)),
            FoundKey(name: "GITHUB_TOKEN", sightings: [.login("gh")], value: FoundKeyValue(Self.fakeGitHub)),
        ], kept: [])
        #expect(KeysScreen.found(plan.offers) == """
            ◆ rv found 2 keys your agents can read
              OPENAI_API_KEY  ~/.zshrc:12  → api.openai.com
              GITHUB_TOKEN    gh login     → api.github.com · github-read

            """)
        #expect(KeysScreen.question(2) == "  Keep them? ⏎ ")
        #expect(KeysScreen.question(1) == "  Keep it? ⏎ ")
    }

    @Test func screen_resultEndsWithOneNextCommand() {
        let text = KeysScreen.result(
            kept: ["OPENAI_API_KEY"], failed: [("GITHUB_TOKEN", "could not store it")],
            exposures: [KeyExposure(name: "OPENAI_API_KEY", sighting: .shellFile(path: "~/.zshrc", line: 12))])
        #expect(text == """
            ✓ Kept 1 · agents get a stand-in, never the key
            ✕ GITHUB_TOKEN not kept: could not store it
            ◐ ~/.zshrc:12 still exports OPENAI_API_KEY · delete that line
            → rv run --secret OPENAI_API_KEY -- <command>

            """)
        #expect(text.split(separator: "\n").filter { $0.hasPrefix("→") }.count == 1)
    }
}
