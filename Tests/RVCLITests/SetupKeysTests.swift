import ArgumentParser
import Foundation
import RVIsolation
import RVPolicy
import RVTheme
import Testing
@testable import RVCLI

/// `rv setup keys` and the keys step after `rv setup`, end to end on a temp
/// HOME with a fake keychain. Every value is fake, and every test checks
/// that no value reaches stdout, stderr or any file rv writes.
@Suite("rv setup keys")
struct SetupKeysTests {
    static let fakeOpenAI = "sk-fake-openai-setupkeys-0000"
    static let fakeGitHub = "ghp_fakeSetupKeysToken0000"
    static let fakeValues = [fakeOpenAI, fakeGitHub]

    struct Machine {
        let home: HomeDirectory
        let secrets: SecretsCLIFixture
        var homeURL: URL { URL(fileURLWithPath: home.rawValue, isDirectory: true) }
        var zshrc: URL { homeURL.appendingPathComponent(".zshrc") }

        init(withKeys: Bool = true) throws {
            home = try isolatedHome()
            secrets = try SecretsCLIFixture()
            guard withKeys else { return }
            try Data("# my shell\nalias ll='ls -l'\nexport OPENAI_API_KEY=\(SetupKeysTests.fakeOpenAI)\n".utf8).write(to: zshrc)
            let gh = homeURL.appendingPathComponent(".config/gh", isDirectory: true)
            try FileManager.default.createDirectory(at: gh, withIntermediateDirectories: true)
            try Data("github.com:\n    user: someone\n    oauth_token: \(SetupKeysTests.fakeGitHub)\n".utf8)
                .write(to: gh.appendingPathComponent("hosts.yml"))
        }

        func environment() -> SecretsEnvironment {
            secrets.environment()
        }

        func stored(_ name: String) -> Data? {
            secrets.keychain.items.withLock { $0["\(SecretKeychain.service)/\(name)"] }
        }

        func tearDown() {
            secrets.tearDown()
            try? FileManager.default.removeItem(at: homeURL)
        }

        /// Every file rv may have written (its config folder, and HOME
        /// minus the two files the test wrote the values into).
        func filesHoldingAValue() -> [String] {
            let fixture = secrets
            let seeded: Set<String> = [zshrc.path, homeURL.appendingPathComponent(".config/gh/hosts.yml").path]
            var hits: [String] = []
            for root in [fixture.directory, homeURL] {
                let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
                while let url = walker?.nextObject() as? URL {
                    guard seeded.contains(url.path) == false, let data = try? Data(contentsOf: url) else { continue }
                    let text = String(decoding: data, as: UTF8.self)
                    if SetupKeysTests.fakeValues.contains(where: text.contains) { hits.append(url.path) }
                }
            }
            return hits
        }
    }

    func run(
        _ mode: SetupKeysRun.Mode, _ machine: Machine, environment: [String: String] = [:], tty: Bool = true,
        answer: String? = "\n", owner: Bool = true, style: KeysPromptStyle = .questionThenPassword,
        capture: CLIOutputCapture
    ) async throws -> Int32 {
        let secrets = machine.environment()
        return try await withCLIProcess(
            home: machine.home, environment: environment, stdinIsTTY: tty, stdoutIsTTY: tty, stdinText: answer,
            ownerAuthOutcome: owner ? .authenticated : nil, output: capture
        ) {
            await SetupKeysRun.run(
                mode, home: machine.home, environment: environment, secrets: secrets, palette: colorOffPalette,
                style: style)
        }
    }

    func expectNoValue(_ capture: CLIOutputCapture, _ machine: Machine) throws {
        for value in Self.fakeValues {
            #expect(capture.stdout.contains(value) == false)
            #expect(capture.stderr.contains(value) == false)
        }
        #expect(machine.filesHoldingAValue() == [])
    }

    @Test func keepsWhatItFinds_byNameOnly_andNamesTheLineToDelete() async throws {
        let machine = try Machine()
        defer { machine.tearDown() }
        let before = try Data(contentsOf: machine.zshrc)
        let capture = CLIOutputCapture()
        let code = try await run(.explicit, machine, capture: capture)

        #expect(code == 0)
        #expect(capture.stdout == """
            ◆ rv found 2 keys · OPENAI_API_KEY in ~/.zshrc:3 · GITHUB_TOKEN from gh
              Keep them? ⏎   password · ✓
            ✓ Kept. Your agents can use them. They can't leak them.
            ◐ ~/.zshrc:3 still exports OPENAI_API_KEY · delete that line
            ◐ gh's login file still holds GITHUB_TOKEN · agents can read it
            → rv run --secret OPENAI_API_KEY --secret GITHUB_TOKEN -- <command>

            """)
        #expect(capture.stderr.isEmpty)
        #expect(machine.stored("OPENAI_API_KEY") == Data(Self.fakeOpenAI.utf8))
        #expect(machine.stored("GITHUB_TOKEN") == Data(Self.fakeGitHub.utf8))
        // Kept the way `rv secrets add NAME` keeps a well-known name.
        let configuration = try SecretsRun.configuration(machine.environment()).get()
        let openAI = try #require(configuration.secret(named: "OPENAI_API_KEY"))
        guard case .gateway(let binding) = openAI.delivery else {
            Issue.record("OPENAI_API_KEY is not delivered through the gateway")
            return
        }
        #expect(binding.upstream.host == "api.openai.com")
        #expect(binding.allow.isEmpty == false)
        #expect(openAI.description == "kept by rv setup from ~/.zshrc:3")
        // The shell file is never edited.
        #expect(try Data(contentsOf: machine.zshrc) == before)
        try expectNoValue(capture, machine)
    }

    /// macOS (v6c): no question; the Touch ID sheet is the one question,
    /// and no method is claimed afterwards (it may have been the password).
    @Test func touchIDSheet_isTheOnlyQuestion() async throws {
        let machine = try Machine()
        defer { machine.tearDown() }
        let capture = CLIOutputCapture()
        #expect(try await run(.explicit, machine, answer: nil, style: .touchIDSheet, capture: capture) == 0)
        #expect(capture.stdout.hasPrefix("""
            ◆ rv found 2 keys · OPENAI_API_KEY in ~/.zshrc:3 · GITHUB_TOKEN from gh
            ✓ Kept. Your agents can use them. They can't leak them.

            """))
        #expect(capture.stdout.contains("Keep them") == false)
        #expect(capture.stdout.contains("Touch ID") == false)
        #expect(machine.stored("OPENAI_API_KEY") == Data(Self.fakeOpenAI.utf8))

        let cancelled = try Machine()
        defer { cancelled.tearDown() }
        let refused = CLIOutputCapture()
        #expect(try await run(.explicit, cancelled, answer: nil, owner: false, style: .touchIDSheet, capture: refused)
            == OwnerConfirmation.refusalExitCode)
        #expect(refused.stdout.hasSuffix("from gh\n  Nothing changed.\n→ rv setup keys\n"))
        #expect(cancelled.stored("OPENAI_API_KEY") == nil)
    }

    /// Ctrl-D (end of input with no newline) and no answer at all are a no, never Enter.
    @Test("Ctrl-D or no answer declines", arguments: [String?.none, "", "y"])
    func endOfInput_declines(answer: String?) async throws {
        let machine = try Machine()
        defer { machine.tearDown() }
        let capture = CLIOutputCapture()
        #expect(try await run(.explicit, machine, answer: answer, capture: capture) == 0)
        #expect(capture.stdout.hasSuffix("  Keep them? ⏎   Nothing changed.\n→ rv setup keys\n"))
        #expect(machine.stored("OPENAI_API_KEY") == nil)
    }

    @Test func afterSetup_skipsUnderCI() async throws {
        let machine = try Machine()
        defer { machine.tearDown() }
        let capture = CLIOutputCapture()
        #expect(try await run(.afterSetup, machine, environment: ["CI": "true"], capture: capture) == 0)
        #expect(capture.stdout.isEmpty)
        #expect(machine.stored("OPENAI_API_KEY") == nil)
    }

    /// Review blocker 1, end to end: a value planted in the environment is never kept under the file's name.
    @Test func environmentThatDisagreesWithTheFile_keepsNeither() async throws {
        let machine = try Machine()
        defer { machine.tearDown() }
        let capture = CLIOutputCapture()
        let planted = ["OPENAI_API_KEY": "sk-fake-planted-by-agent-0000"]
        #expect(try await run(.explicit, machine, environment: planted, capture: capture) == 0)
        #expect(capture.stdout.hasPrefix("""
            ◆ rv found 1 key · GITHUB_TOKEN from gh
            ◐ OPENAI_API_KEY in ~/.zshrc:3 differs from the environment's · kept neither · rv secrets add OPENAI_API_KEY

            """))
        #expect(machine.stored("OPENAI_API_KEY") == nil)
        #expect(capture.stdout.contains("sk-fake-planted") == false)
    }

    @Test func keep_rechecksWhatRvKeeps_afterTheOwnerCheck() throws {
        let machine = try Machine()
        defer { machine.tearDown() }
        let offers = KeyPlan.make(
            KeyScan.find(KeyScanInput(environment: ["OPENAI_API_KEY": Self.fakeOpenAI]), names: KnownSecretDefaults.names),
            kept: []).offers
        let original = Data("sk-fake-kept-meanwhile-0000".utf8)
        _ = SecretsRun.set(
            name: "OPENAI_API_KEY", value: original,
            definition: SecretsRun.definitionForSet(
                name: "OPENAI_API_KEY", isNew: true, gateway: nil, baseURLEnv: nil, placeholderPrefix: "",
                environment: false
            ).definition,
            agents: [], description: nil, environment: machine.environment())
        let moved = SetupKeysRun.keep(offers, secrets: machine.environment())
        #expect(moved.kept.isEmpty)
        #expect(moved.failed.map(\.name) == ["OPENAI_API_KEY"])
        #expect(machine.stored("OPENAI_API_KEY") == original)
    }

    @Test("anything but Enter, y or yes keeps nothing", arguments: ["n\n", "no\n", "q\n"])
    func declined_changesNothing(answer: String) async throws {
        let machine = try Machine()
        defer { machine.tearDown() }
        let capture = CLIOutputCapture()
        #expect(try await run(.explicit, machine, answer: answer, capture: capture) == 0)
        #expect(capture.stdout.hasSuffix("  Keep them? ⏎   Nothing changed.\n→ rv setup keys\n"))
        #expect(machine.stored("OPENAI_API_KEY") == nil)
        #expect(try SecretsRun.configuration(machine.environment()).get().secrets.isEmpty)
        try expectNoValue(capture, machine)
    }

    @Test func ownerRefused_keepsNothing_andExits77() async throws {
        let machine = try Machine()
        defer { machine.tearDown() }
        let capture = CLIOutputCapture()
        #expect(try await run(.explicit, machine, owner: false, capture: capture) == OwnerConfirmation.refusalExitCode)
        #expect(capture.stderr.contains("needs owner authentication"))
        #expect(capture.stdout.hasSuffix("  Nothing changed.\n→ rv setup keys\n"))
        #expect(machine.stored("OPENAI_API_KEY") == nil)
        try expectNoValue(capture, machine)
    }

    @Test func noTerminal_refusesBeforeReadingAnything() async throws {
        let machine = try Machine()
        defer { machine.tearDown() }
        let capture = CLIOutputCapture()
        #expect(try await run(.explicit, machine, tty: false, capture: capture) == OwnerConfirmation.refusalExitCode)
        #expect(capture.stdout.isEmpty)
        #expect(capture.stderr == "✕ rv setup keys needs you at a terminal. Nothing was read or moved.\n")
        #expect(machine.stored("OPENAI_API_KEY") == nil)
    }

    @Test("an agent's markers refuse it even on a terminal", arguments: [
        ["CLAUDECODE": "1"], ["CODEX_THREAD_ID": "t-1"], ["CURSOR_AGENT": "1"],
    ])
    func agent_refused(environment: [String: String]) async throws {
        let machine = try Machine()
        defer { machine.tearDown() }
        let capture = CLIOutputCapture()
        let code = try await run(.explicit, machine, environment: environment, capture: capture)
        #expect(code == OwnerConfirmation.refusalExitCode)
        #expect(capture.stdout.isEmpty)
        #expect(capture.stderr.hasPrefix("✕ rv setup keys runs only in your own terminal, not inside "))
        #expect(machine.stored("OPENAI_API_KEY") == nil)
        #expect(machine.stored("GITHUB_TOKEN") == nil)
    }

    @Test func afterSetup_isSilentForAnAgentOrAPipe() async throws {
        let machine = try Machine()
        defer { machine.tearDown() }
        for (environment, tty) in [([String: String](), false), (["CLAUDECODE": "1"], true)] {
            let capture = CLIOutputCapture()
            #expect(try await run(.afterSetup, machine, environment: environment, tty: tty, capture: capture) == 0)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.isEmpty)
        }
        #expect(machine.stored("OPENAI_API_KEY") == nil)
    }

    @Test func afterSetup_ownerRefusalKeepsSetupsExitCode() async throws {
        let machine = try Machine()
        defer { machine.tearDown() }
        let capture = CLIOutputCapture()
        #expect(try await run(.afterSetup, machine, owner: false, capture: capture) == 0)
        #expect(capture.stdout.hasPrefix("\n◆ rv found 2 keys · OPENAI_API_KEY in ~/.zshrc:3 · GITHUB_TOKEN from gh\n"))
        #expect(machine.stored("OPENAI_API_KEY") == nil)
    }

    @Test func alreadyKept_isNeverReplaced_butItsLineIsNamed() async throws {
        let machine = try Machine()
        defer { machine.tearDown() }
        let original = Data("sk-fake-kept-before-0000".utf8)
        _ = SecretsRun.set(
            name: "OPENAI_API_KEY", value: original,
            definition: SecretsRun.definitionForSet(
                name: "OPENAI_API_KEY", isNew: true, gateway: nil, baseURLEnv: nil, placeholderPrefix: "",
                environment: false
            ).definition,
            agents: [], description: nil, environment: machine.environment())
        let capture = CLIOutputCapture()
        #expect(try await run(.explicit, machine, capture: capture) == 0)
        #expect(capture.stdout.hasPrefix("""
            ◆ rv found 1 key · GITHUB_TOKEN from gh
            ◐ ~/.zshrc:3 still exports OPENAI_API_KEY, which rv keeps · delete that line
              Keep it? ⏎
            """))
        #expect(machine.stored("OPENAI_API_KEY") == original)
        try expectNoValue(capture, machine)
    }

    @Test func nothingFound_saysWhatItChecked() async throws {
        let machine = try Machine(withKeys: false)
        defer { machine.tearDown() }
        try Data("export PATH=/usr/bin\n".utf8).write(to: machine.homeURL.appendingPathComponent(".bashrc"))
        let capture = CLIOutputCapture()
        #expect(try await run(.explicit, machine, capture: capture) == 0)
        #expect(capture.stdout == "✓ No keys your agents can read · checked 1 shell file, the environment, gh and vercel\n")
        let silent = CLIOutputCapture()
        #expect(try await run(.afterSetup, machine, capture: silent) == 0)
        #expect(silent.stdout.isEmpty)
    }

    @Test func colourGoesOnTheGlyphOnly() {
        let text = KeysScreen.result(kept: ["OPENAI_API_KEY"], failed: [], exposures: [])
        let color = BoxInk.palette(isTerminal: true, environment: ["TERM": "xterm-256color"])
        let painted = BoxInk.paint(text, palette: color)
        #expect(painted != text)
        #expect(painted.contains("✓\(color.reset) Kept. Your agents can use it. They can't leak it."))
        for environment in [["TERM": "xterm-256color", "NO_COLOR": "1"], ["TERM": "dumb"]] {
            #expect(BoxInk.paint(text, palette: BoxInk.palette(isTerminal: true, environment: environment)) == text)
        }
        #expect(BoxInk.paint(text, palette: BoxInk.palette(isTerminal: false, environment: ["TERM": "xterm-256color"])) == text)
    }

    @Test func parses_asASubcommandOfSetup() throws {
        #expect(try RV.parseAsRoot(["setup", "keys"]) is SetupKeys)
        #expect(try RV.parseAsRoot(["setup", "--force"]) is Setup)
        #expect(HelpDispatch.text(.setup, palette: colorOffPalette).contains("rv setup keys"))
    }

    @Test func shellFiles_followZDOTDIR_andShowTheHomeAsTilde() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let files = KeyScanSources.shellFiles(home: home, environment: ["ZDOTDIR": "/Users/someone/.config/zsh"])
        #expect(files.first?.path == "/Users/someone/.config/zsh/.zshenv")
        #expect(files.map { KeyScanSources.displayPath($0, home: home) }.contains("~/.config/zsh/.zshrc"))
        #expect(files.map { KeyScanSources.displayPath($0, home: home) }.contains("~/.bashrc"))
        #expect(KeyScanSources.displayPath(URL(fileURLWithPath: "/etc/profile"), home: home) == "/etc/profile")
    }
}
