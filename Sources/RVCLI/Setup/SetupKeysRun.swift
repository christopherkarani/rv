import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVFileStore
import RVIsolation
import RVPolicy
import RVTheme

/// `rv setup keys`: the keys step of `rv setup` on its own, to run again
/// later. The hook guard refuses it from an agent (`SelfProtectionGuard`).
struct SetupKeys: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Find the API keys your agents can read and keep them in rv, by name only."
    )

    func run() async throws {
        let home = try CommandContext.requireHome(command: "setup keys")
        let environment = CLIProcess.environment()
        let palette = BoxInk.palette(isTerminal: CLIProcess.stdoutIsTTY(), environment: environment)
        let code = await SetupKeysRun.run(
            .explicit, home: home, environment: environment, secrets: .live(home: home), palette: palette)
        if code != 0 { throw ExitCode(code) }
    }
}

/// The keys step: find the well-known keys agents can read (shell startup
/// files, this environment, the gh and Vercel logins), list them by name,
/// ask once, check the owner, and keep each in rv the way
/// `rv secrets add NAME` would. Values go from the file straight to the
/// keychain writer; none is printed, logged or sent anywhere.
enum SetupKeysRun {
    enum Mode: Sendable, Equatable {
        /// After a successful `rv setup` on a terminal: silent unless it
        /// finds something, and never changes setup's exit code.
        case afterSetup
        /// `rv setup keys`: says why when it cannot run, exits 77 then.
        case explicit
    }

    static func run(
        _ mode: Mode,
        home: HomeDirectory,
        environment: [String: String],
        secrets: SecretsEnvironment,
        palette: Palette,
        terminal: KeysTerminal = .current(),
        style: KeysPromptStyle = .platform,
        confirmOwner: (String) async throws -> Void = { _ = try await OwnerConfirmation.check($0) }
    ) async -> Int32 {
        let explicit = mode == .explicit
        let gate = KeysGate.decide(
            interactive: terminal.isInteractive(), agents: AgentHostMarkers.callingHosts(in: environment),
            ci: explicit == false && (environment["CI"] ?? "").isEmpty == false)
        guard gate == .open else {
            guard explicit, let refusal = KeysScreen.refusal(gate) else { return 0 }
            CommandContext.writeStderr(BoxInk.paint(refusal, palette: palette))
            return OwnerConfirmation.refusalExitCode
        }
        guard let kept = keptNames(secrets, explicit: explicit) else { return explicit ? 1 : 0 }
        let loaded = KeyScanSources.load(home: home, environment: environment)
        let plan = KeyPlan.make(KeyScan.find(loaded.input, names: KnownSecretDefaults.names), kept: kept)
        func say(_ text: String) { CommandContext.writeStdout(BoxInk.paint(text, palette: palette)) }
        let lead = explicit ? "" : "\n"
        let notes = KeysScreen.exposureLines(plan.keptButExposed, kept: true) + KeysScreen.conflictLines(plan.conflicts)

        guard plan.offers.isEmpty == false else {
            if notes.isEmpty == false {
                say(lead + notes)
            } else if explicit {
                say(KeysScreen.nothingFound(shellFiles: loaded.shellFileCount))
            }
            return 0
        }
        say(lead + KeysScreen.found(plan.offers) + notes)
        if style.asksFirst {
            CommandContext.writeStdout(KeysScreen.question(plan.offers.count))
            // No answer (Ctrl-D, the time limit, no terminal) is a no.
            let answer = terminal.readAnswer()?.trimmingCharacters(in: .whitespaces).lowercased()
            guard let answer, answer.isEmpty || answer == "y" || answer == "yes" else {
                say(KeysScreen.declined)
                return 0
            }
        }
        do {
            try await confirmOwner(KeysScreen.ownerSummary(plan.offers))
        } catch {
            CommandContext.writeStderr("\(error)\n")
            say(KeysScreen.declined)
            return explicit ? OwnerConfirmation.refusalExitCode : 0
        }
        if let approved = style.approvedLine { say(approved) }
        let moved = keep(plan.offers, secrets: secrets)
        let exposures = plan.offers.filter { moved.kept.contains($0.name) }
            .flatMap { KeyPlan.exposures(of: $0.name, sightings: $0.sightings) }
        say(KeysScreen.result(kept: moved.kept, failed: moved.failed, exposures: exposures))
        return explicit && moved.failed.isEmpty == false ? 1 : 0
    }

    /// The names rv keeps now, or nil (said, when explicit) when secrets.json cannot be read.
    static func keptNames(_ secrets: SecretsEnvironment, explicit: Bool) -> Set<String>? {
        switch SecretsRun.configuration(secrets) {
        case .failure(let failure):
            if explicit { CommandContext.writeStderr("rv setup keys: \(failure.message)\n") }
            return nil
        case .success(let configuration):
            return Set(configuration.secrets.map(\.name))
        }
    }

    /// Each offer kept as `rv secrets add NAME` keeps a well-known name: the
    /// gateway defaults, least-privilege allow rules, the rv keychain. What
    /// rv keeps is read again first: a name kept while the owner was being
    /// asked is never replaced.
    static func keep(
        _ offers: [KeyOffer], secrets: SecretsEnvironment
    ) -> (kept: [String], failed: [(name: String, reason: String)]) {
        var kept: [String] = []
        var failed: [(name: String, reason: String)] = []
        for offer in offers {
            switch SecretsRun.configuration(secrets) {
            case .failure(let failure):
                failed.append((offer.name, failure.message))
                continue
            case .success(let configuration) where configuration.secret(named: offer.name) != nil:
                failed.append((offer.name, "rv already keeps one; nothing was replaced"))
                continue
            case .success:
                break
            }
            let definition = SecretsRun.definitionForSet(
                name: offer.name, isNew: true, gateway: nil, baseURLEnv: nil, placeholderPrefix: "",
                environment: false
            ).definition
            let origin = "kept by rv setup from \(offer.source.label)"
            switch SecretsRun.set(
                name: offer.name, value: offer.value.bytes, definition: definition, agents: [],
                description: origin.count <= 200 ? origin : nil, environment: secrets)
            {
            case .success: kept.append(offer.name)
            case .failure(let failure): failed.append((offer.name, failure.message))
            }
        }
        return (kept, failed)
    }
}

/// The terminal the keys step asks on. Production: stdout is a terminal
/// and this process has a controlling terminal (`/dev/tty`), which an
/// agent's tool call does not; the answer is read from `/dev/tty`, so the
/// step also works after `curl … | sh`. Tests: the context's TTY flags and
/// `stdinText`, never the real terminal.
struct KeysTerminal: Sendable {
    var isInteractive: @Sendable () -> Bool
    var readAnswer: @Sendable () -> String?

    static func current() -> KeysTerminal {
        if let context = CLIProcess.context {
            return KeysTerminal(
                isInteractive: { context.stdinIsTTY == true && context.stdoutIsTTY == true },
                readAnswer: {
                    // A line ends with a newline; text without one is Ctrl-D.
                    guard let text = context.stdinText, let end = text.firstIndex(of: "\n") else { return nil }
                    return String(text[..<end])
                })
        }
        return KeysTerminal(
            isInteractive: {
                guard isatty(STDOUT_FILENO) == 1 else { return false }
                let fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
                guard fd >= 0 else { return false }
                close(fd)
                return true
            },
            readAnswer: { readLineFromTerminal() })
    }

    /// How long the question waits for an answer before it reads as no.
    static let answerTimeoutMilliseconds: Int32 = 120_000

    /// One short line from `/dev/tty`. nil without a terminal, on Ctrl-D
    /// (end of input before a newline), or when nobody answers within
    /// `answerTimeoutMilliseconds`, so automation holding a pty never hangs.
    private static func readLineFromTerminal() -> String? {
        let fd = open("/dev/tty", O_RDONLY | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        var remaining = answerTimeoutMilliseconds
        while remaining > 0 {
            var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let started = Date()
            let ready = poll(&waiting, 1, min(remaining, 1_000))
            remaining -= Int32(Date().timeIntervalSince(started) * 1_000) + (ready == 0 ? 0 : 1)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { return nil }
            if ready == 0 { continue }
            guard read(fd, &byte, 1) == 1 else { return nil }
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
            if bytes.count > 64 { return String(decoding: bytes, as: UTF8.self) }
        }
        return nil
    }
}

/// Loads what `KeyScan` reads, from known places only, never a search:
/// the POSIX shell startup files, the gh CLI's `hosts.yml` and the Vercel
/// CLI's `auth.json`. Each must be a regular file of at most 1 MiB.
enum KeyScanSources {
    static let maximumBytes = 1 << 20

    static func load(home: HomeDirectory, environment: [String: String]) -> (input: KeyScanInput, shellFileCount: Int) {
        let homeURL = URL(fileURLWithPath: home.rawValue, isDirectory: true)
        var input = KeyScanInput(environment: environment)
        for url in shellFiles(home: homeURL, environment: environment) {
            guard let data = readSmall(url) else { continue }
            input.shellFiles.append(ShellStartupFile(
                displayPath: displayPath(url, home: homeURL), contents: String(decoding: data, as: UTF8.self)))
        }
        input.ghHosts = readSmall(ghHosts(home: homeURL, environment: environment))
            .map { String(decoding: $0, as: UTF8.self) }
        input.vercelAuth = LoginRun.vercelAuthFiles(home: homeURL).lazy.compactMap(readSmall).first
        return (input, input.shellFiles.count)
    }

    /// zsh's files (under `$ZDOTDIR` when set), then bash's and `.profile`,
    /// in the order a login shell reads them.
    static func shellFiles(home: URL, environment: [String: String]) -> [URL] {
        let zdot = environment["ZDOTDIR"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? home
        return [".zshenv", ".zprofile", ".zshrc", ".zlogin"].map { zdot.appendingPathComponent($0) }
            + [".bash_profile", ".bash_login", ".profile", ".bashrc"].map { home.appendingPathComponent($0) }
    }

    static func ghHosts(home: URL, environment: [String: String]) -> URL {
        if let dir = environment["GH_CONFIG_DIR"], dir.hasPrefix("/") {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("hosts.yml")
        }
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        return config.appendingPathComponent("gh/hosts.yml")
    }

    /// `~/.zshrc` for a file in the home folder; otherwise the path, escaped for display.
    static func displayPath(_ url: URL, home: URL) -> String {
        let root = home.path.hasSuffix("/") ? home.path : home.path + "/"
        if url.path.hasPrefix(root) { return "~/" + DisplayedText.field(String(url.path.dropFirst(root.count))) }
        return DisplayedText.field(url.path)
    }

    /// The file's bytes when it is a regular file (a symlink to one counts)
    /// of at most `maximumBytes`; nil for anything else. The open does not
    /// block, so a FIFO planted at the path cannot hang setup.
    static func readSmall(_ url: URL) -> Data? {
        readRegularFile(url, limit: maximumBytes)
    }
}
