import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIsolation
import RVPolicy

/// One third-party app `rv login` can hold a credential for. The value
/// itself is an ordinary rv secret (Keychain-backed, gateway delivery);
/// a login only adds the provider's name, upstream, and import sources.
struct LoginProvider: Equatable, Sendable {
    var id: String
    var displayName: String
    var secretName: String
    var upstream: String
    var baseURLEnv: String

    static let all: [LoginProvider] = [
        LoginProvider(
            id: "vercel", displayName: "Vercel", secretName: "VERCEL_TOKEN",
            upstream: "https://api.vercel.com", baseURLEnv: "VERCEL_BASE_URL"),
        LoginProvider(
            id: "github", displayName: "GitHub", secretName: "GITHUB_TOKEN",
            upstream: "https://api.github.com", baseURLEnv: "GITHUB_API_URL"),
    ]

    static func named(_ raw: String) -> LoginProvider? {
        let key = raw.lowercased()
        return all.first { $0.id == key || $0.secretName.lowercased() == key }
    }
}

enum LoginRun {
    struct Row: Encodable, Equatable {
        var provider: String
        var displayName: String
        var secretName: String
        var connected: Bool
        var delivery: String?
        var upstream: String?
        var source: String?
        var profiles: [String]
        var checkOK: Bool?
        var fingerprint: String?
    }

    struct Report: Encodable, Equatable {
        var logins: [Row]
    }

    static func list(
        _ configuration: SecretsConfiguration, profiles: [RuntimeResourceProfile],
        environment: SecretsEnvironment
    ) -> Report {
        let secrets = SecretsRun.list(configuration, profiles: profiles)
        let byName = Dictionary(uniqueKeysWithValues: secrets.secrets.map { ($0.name, $0) })
        let rows = LoginProvider.all.map { provider -> Row in
            guard let secret = byName[provider.secretName] else {
                return Row(
                    provider: provider.id, displayName: provider.displayName,
                    secretName: provider.secretName, connected: false, profiles: [])
            }
            var checkOK: Bool?
            var fingerprint: String?
            if case .success(let checked) = SecretsRun.check(
                configuration, names: [provider.secretName], environment: environment),
                let first = checked.first
            {
                checkOK = first.ok
                fingerprint = first.fingerprint
            }
            return Row(
                provider: provider.id, displayName: provider.displayName,
                secretName: provider.secretName, connected: true,
                delivery: secret.delivery, upstream: secret.upstream,
                source: secret.source, profiles: secret.profiles,
                checkOK: checkOK, fingerprint: fingerprint)
        }
        return Report(logins: rows)
    }

    static func listText(_ report: Report) -> String {
        guard report.logins.isEmpty == false else { return "No logins supported.\n" }
        let width = report.logins.map(\.displayName.count).max() ?? 0
        return report.logins.map { row -> String in
            let name = row.displayName.padding(toLength: width, withPad: " ", startingAt: 0)
            guard row.connected else {
                return "\(name)  not connected  run: rv login connect \(row.provider)"
            }
            var line = "\(name)  connected  \(row.delivery ?? "")"
            if let checkOK = row.checkOK {
                line += checkOK ? "  ok" : "  check failed"
            }
            if let fingerprint = row.fingerprint { line += "  fingerprint \(fingerprint)" }
            line += "  profiles: \(row.profiles.isEmpty ? "-" : row.profiles.joined(separator: ","))"
            return line
        }.joined(separator: "\n") + "\n"
    }

    /// Stores `value` as the provider's secret with gateway delivery.
    /// `origin` names where the value came from (imported CLI login,
    /// environment, pasted); it is recorded in the description, never
    /// alongside the value.
    static func connect(
        provider raw: String, value: Data, origin: String, environment: SecretsEnvironment
    ) -> Result<String, CommandFailure> {
        guard let provider = LoginProvider.named(raw) else {
            return .failure(CommandFailure(unknownProvider(raw)))
        }
        let existing: Bool
        switch SecretsRun.configuration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): existing = loaded.secret(named: provider.secretName) != nil
        }
        // Existing secrets keep their stored delivery; `secrets set`
        // only accepts a delivery when the secret is first defined.
        let definition: SecretsRun.Definition? = existing
            ? nil
            : .gateway(upstream: provider.upstream, baseURLEnv: provider.baseURLEnv, placeholderPrefix: "")
        switch SecretsRun.set(
            name: provider.secretName, value: value, definition: definition, agents: [],
            description: existing ? nil : "\(provider.displayName) login (\(origin))",
            environment: environment)
        {
        case .failure(let failure): return .failure(failure)
        case .success(let text):
            return .success("Connected \(provider.displayName) (\(origin)).\n" + text)
        }
    }

    static func logout(
        provider raw: String, environment: SecretsEnvironment
    ) -> Result<String, CommandFailure> {
        guard let provider = LoginProvider.named(raw) else {
            return .failure(CommandFailure(unknownProvider(raw)))
        }
        return SecretsRun.remove(name: provider.secretName, environment: environment)
            .map { "Disconnected \(provider.displayName).\n" + $0 }
    }

    static func unknownProvider(_ raw: String) -> String {
        let known = LoginProvider.all.map(\.id).joined(separator: ", ")
        return "\(DisplayedText.field(raw)) is not a login rv knows (supported: \(known))"
    }

    /// The token inside Vercel CLI's `auth.json` (`{"token": "…"}`), or nil.
    static func vercelAuthToken(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = object["token"] as? String
        else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return Data(trimmed.utf8)
    }

    /// Places an existing Vercel CLI login may live, most specific first.
    static func vercelAuthFiles(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".local/share/com.vercel.cli/auth.json"),
            home.appendingPathComponent("Library/Application Support/com.vercel.cli/auth.json"),
            home.appendingPathComponent(".vercel/auth.json"),
        ]
    }
}

/// Where a provider's existing credential is found on this machine.
/// Returns the value plus a short origin label; nil means “ask the user”.
enum LoginAcquire {
    static func value(
        provider: LoginProvider, home: URL, variables: [String: String]
    ) -> (value: Data, origin: String)? {
        switch provider.id {
        case "vercel":
            if let token = variables["VERCEL_TOKEN"], token.isEmpty == false {
                return (Data(token.utf8), "imported from $VERCEL_TOKEN")
            }
            for file in LoginRun.vercelAuthFiles(home: home) {
                if let data = try? Data(contentsOf: file), let token = LoginRun.vercelAuthToken(data) {
                    return (token, "imported from Vercel CLI login")
                }
            }
            return nil
        case "github":
            for variable in ["GH_TOKEN", "GITHUB_TOKEN"] {
                if let token = variables[variable], token.isEmpty == false {
                    return (Data(token.utf8), "imported from $\(variable)")
                }
            }
            if let token = ghAuthToken(variables: variables) {
                return (token, "imported from gh CLI login")
            }
            return nil
        default:
            return nil
        }
    }

    /// `gh auth token` from the installed GitHub CLI, bounded and silent.
    static func ghAuthToken(variables: [String: String]) -> Data? {
        let searched = (variables["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        guard let gh = searched.lazy.map({ ($0 as NSString).appendingPathComponent("gh") })
            .first(where: { access($0, X_OK) == 0 })
        else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["auth", "token"]
        process.environment = variables
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.isEmpty == false else { return nil }
        return Data(token.utf8)
    }
}

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Log in to apps once; agents use the credential through rv.",
        subcommands: [LoginList.self, LoginCheck.self, LoginConnect.self, LoginLogout.self],
        defaultSubcommand: LoginList.self
    )
}

struct LoginList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "Show which app logins rv holds and whether they resolve.")

    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "login list", format: format)
        let environment = SecretsEnvironment.live(home: try ctx.requireHome())
        switch SecretsRun.configuration(environment) {
        case .failure(let failure):
            try ctx.fail("rv login list: \(failure.message)\n")
        case .success(let configuration):
            let report = LoginRun.list(
                configuration, profiles: SecretsRun.profiles(environment), environment: environment)
            ctx.writeStdout(ctx.explicitRobot ? SecretsRun.robotJSON(report) : LoginRun.listText(report))
        }
    }
}

struct LoginCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check", abstract: "Resolve app logins and show fingerprints, never values.")

    @Argument(help: "Providers (vercel, github). Default: all connected.") var providers: [String] = []
    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "login check", format: format)
        let environment = SecretsEnvironment.live(home: try ctx.requireHome())
        var names: [String] = []
        for raw in providers {
            guard let provider = LoginProvider.named(raw) else {
                try ctx.fail("rv login check: \(LoginRun.unknownProvider(raw))\n")
                return
            }
            names.append(provider.secretName)
        }
        let rows: [SecretsRun.CheckRow]
        switch SecretsRun.configuration(environment).flatMap({
            SecretsRun.check($0, names: names, environment: environment)
        }) {
        case .failure(let failure): try ctx.fail("rv login check: \(failure.message)\n")
        case .success(let checked): rows = checked
        }
        let text = ctx.explicitRobot ? SecretsRun.robotJSON(rows) : SecretsRun.checkText(rows)
        if rows.allSatisfy(\.ok) {
            ctx.writeStdout(text)
        } else {
            try ctx.emit(stdout: text, exitCode: 1)
        }
    }
}

struct LoginConnect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Connect an app login: import the existing CLI login, or paste a token.",
        discussion: """
            rv first looks for a login you already have (the provider's CLI
            auth file, its token environment variable, or `gh auth token`).
            If none is found, the token is read from a hidden prompt, or
            from stdin when piped:
              rv login connect vercel
              printf %s "$VERCEL_TOKEN" | rv login connect vercel --stdin
            The value is stored in the Keychain as the provider's secret
            with gateway delivery; agents receive a placeholder, never it.
            """
    )

    @Argument(help: "Provider: vercel or github.") var provider: String
    @Flag(name: .customLong("stdin"), help: "Read the token from stdin instead of importing.")
    var readStdin = false
    @Option(name: .customLong("resource-profile"), help: "Wire the secret into this runtime profile (see `rv init`).")
    var profile: String?

    func validate() throws {
        guard LoginProvider.named(provider) != nil else {
            throw ValidationError(LoginRun.unknownProvider(provider))
        }
    }

    func run() throws {
        let ctx = CommandContext.current(command: "login connect", json: false, robot: false, plain: true, noColor: true)
        let home = try ctx.requireHome()
        let environment = SecretsEnvironment.live(home: home)
        guard let known = LoginProvider.named(provider) else {
            try ctx.fail("rv login connect: \(LoginRun.unknownProvider(provider))\n")
            return
        }
        if let profile {
            switch RuntimeResourcePolicyStore.load(from: environment.configDirectory) {
            case .failure(let error):
                try ctx.fail("rv login connect: \(RuntimeResourcePolicyFile.message(error))\n")
            case .success(let policy):
                if policy.profiles.contains(where: { $0.id == profile }) == false {
                    try ctx.fail(
                        "rv login connect: profile \(DisplayedText.field(profile)) does not exist; run `rv init` to create it\n")
                }
            }
        }
        let acquired: (value: Data, origin: String)?
        if readStdin {
            acquired = SecretsRun.readValue(name: known.secretName, stdinIsTTY: false)
                .map { (value: $0, origin: "pasted token") }
        } else if let found = LoginAcquire.value(
            provider: known, home: URL(fileURLWithPath: home.rawValue), variables: ProcessInfo.processInfo.environment)
        {
            acquired = found
        } else {
            acquired = SecretsRun.readValue(name: known.secretName, stdinIsTTY: isatty(STDIN_FILENO) == 1)
                .map { (value: $0, origin: "pasted token") }
        }
        guard let acquired, acquired.value.isEmpty == false else {
            try ctx.fail("rv login connect: no token found for \(known.displayName); log in with its CLI first, or paste one\n")
            return
        }
        switch LoginRun.connect(
            provider: provider, value: acquired.value, origin: acquired.origin, environment: environment)
        {
        case .failure(let failure): try ctx.fail("rv login connect: \(failure.message)\n")
        case .success(var text):
            if let profile {
                switch InitRun.attachSecret(
                    known.secretName, profileID: profile, configDirectory: environment.configDirectory)
                {
                case .failure(let failure):
                    text += "warning: stored but not wired into profile \(DisplayedText.field(profile)): \(failure.message)\n"
                case .success(true):
                    text += "Wired \(DisplayedText.field(known.secretName)) into profile \(DisplayedText.field(profile)).\n"
                case .success(false):
                    break
                }
            }
            ctx.writeStdout(text)
        }
    }
}

struct LoginLogout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logout", abstract: "Remove an app login: its definition and rv-stored Keychain value.")

    @Argument(help: "Provider: vercel or github.") var provider: String

    func run() throws {
        let ctx = CommandContext.current(command: "login logout", json: false, robot: false, plain: true, noColor: true)
        switch LoginRun.logout(provider: provider, environment: .live(home: try ctx.requireHome())) {
        case .failure(let failure): try ctx.fail("rv login logout: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}
