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

/// Seams for `rv secrets`: where config lives and how values are read and stored.
struct SecretsEnvironment: Sendable {
    var configDirectory: URL
    var resolver: SecretResolver
    var keychain: SecretKeychainWriter
    var managed: ManagedPolicyState = .none

    static func live(home: HomeDirectory) -> SecretsEnvironment {
        SecretsEnvironment(
            configDirectory: RVPolicyPaths.configDirectory(home: home),
            resolver: .live(home: home.rawValue),
            keychain: .live,
            managed: ManagedRun.installed(home: home)
        )
    }
}

enum SecretsRun {
    struct ListRow: Encodable, Equatable {
        var name: String
        var description: String?
        var source: String
        var provider: String
        var delivery: String
        var upstream: String?
        var baseURLEnv: String?
        var agents: [String]?
        var profiles: [String]
        /// Environment delivery puts the real value in the cage.
        var weaker: Bool
    }

    struct ListReport: Encodable, Equatable {
        var secrets: [ListRow]
        var warnings: [String]
    }

    struct CheckRow: Encodable, Equatable {
        var name: String
        var source: String
        var ok: Bool
        var fingerprint: String?
        var error: String?
    }

    enum Definition: Equatable {
        case gateway(upstream: String, baseURLEnv: String, placeholderPrefix: String)
        case environment
    }

    static func configuration(_ environment: SecretsEnvironment) -> Result<SecretsConfiguration, CommandFailure> {
        SecretsConfiguration.load(configDirectory: environment.configDirectory).mapError { CommandFailure($0.message) }
    }

    static func profiles(_ environment: SecretsEnvironment) -> [RuntimeResourceProfile] {
        guard case .success(let policy) = RuntimeResourcePolicyStore.load(from: environment.configDirectory) else {
            return []
        }
        return policy.profiles
    }

    static func list(_ configuration: SecretsConfiguration, profiles: [RuntimeResourceProfile]) -> ListReport {
        let rows = configuration.secrets.map { secret -> ListRow in
            var upstream: String?
            var baseURLEnv: String?
            if case .gateway(let binding) = secret.delivery {
                upstream = binding.upstream.absoluteString
                baseURLEnv = binding.baseURLEnv
            }
            return ListRow(
                name: secret.name,
                description: secret.description,
                source: secret.source.locator,
                provider: secret.source.kind,
                delivery: secret.delivery.summary,
                upstream: upstream,
                baseURLEnv: baseURLEnv,
                agents: secret.agents,
                profiles: profiles.filter { $0.secrets.contains(secret.name) }.map(\.id),
                weaker: secret.delivery == .environment
            )
        }
        var warnings: [String] = []
        for profile in profiles {
            for name in profile.secrets where configuration.secret(named: name) == nil {
                warnings.append("profile \(profile.id) lists \(name), which secrets.json does not define")
            }
        }
        return ListReport(secrets: rows, warnings: warnings)
    }

    static func listText(_ report: ListReport) -> String {
        guard report.secrets.isEmpty == false || report.warnings.isEmpty == false else {
            return "No secrets configured. Add one with:\n"
                + "  rv secrets set NAME --gateway https://api.example.com --base-url-env EXAMPLE_BASE_URL\n"
        }
        let width = report.secrets.map(\.name.count).max() ?? 0
        var lines = report.secrets.map { row -> String in
            var line = row.name.padding(toLength: width, withPad: " ", startingAt: 0)
                + "  \(row.source)  \(row.delivery)"
            line += "  profiles: \(row.profiles.isEmpty ? "-" : row.profiles.joined(separator: ","))"
            if let agents = row.agents { line += "  agents: \(agents.joined(separator: ","))" }
            if row.weaker { line += "  [weaker]" }
            return line
        }
        lines += report.warnings.map { "warning: \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    static func check(
        _ configuration: SecretsConfiguration, names: [String], environment: SecretsEnvironment
    ) -> Result<[CheckRow], CommandFailure> {
        let selected: [SecretDefinition]
        if names.isEmpty {
            selected = configuration.secrets
        } else {
            var picked: [SecretDefinition] = []
            for name in names {
                guard let secret = configuration.secret(named: name) else {
                    return .failure("\(name) is not defined in secrets.json")
                }
                picked.append(secret)
            }
            selected = picked
        }
        let fingerprinter = SecretFingerprinter.load(configDirectory: environment.configDirectory)
        return .success(selected.map { secret in
            if let reason = environment.managed.invalidReason
                ?? SecretOrganizationRules.violation(secret, policy: environment.managed.policy)
            {
                return CheckRow(
                    name: secret.name, source: secret.source.locator, ok: false, fingerprint: nil,
                    error: "organization policy: \(reason)")
            }
            switch environment.resolver.resolve(secret.source) {
            case .success(let value):
                return CheckRow(
                    name: secret.name, source: secret.source.locator, ok: true,
                    fingerprint: fingerprinter?.fingerprint(of: value), error: nil)
            case .failure(let error):
                return CheckRow(
                    name: secret.name, source: secret.source.locator, ok: false, fingerprint: nil,
                    error: error.message)
            }
        })
    }

    static func checkText(_ rows: [CheckRow]) -> String {
        guard rows.isEmpty == false else { return "No secrets configured.\n" }
        let width = rows.map(\.name.count).max() ?? 0
        return rows.map { row in
            let name = row.name.padding(toLength: width, withPad: " ", startingAt: 0)
            if row.ok {
                return "ok    \(name)  fingerprint \(row.fingerprint ?? "unavailable")  \(row.source)"
            }
            return "FAIL  \(name)  \(row.error ?? "unresolved")  \(row.source)"
        }.joined(separator: "\n") + "\n"
    }

    /// Stores `value` in the Keychain (`rv.secrets`/NAME) and, when the
    /// secret is new, adds its definition. Returns the confirmation text.
    static func set(
        name: String, value: Data, definition: Definition?, agents: [String], description: String?,
        environment: SecretsEnvironment
    ) -> Result<String, CommandFailure> {
        guard value.isEmpty == false, value.count <= SecretValue.maximumBytes, value.contains(0) == false else {
            return .failure("the value must be 1 byte to 16 KiB with no NUL bytes")
        }
        let current: SecretsConfiguration
        switch configuration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): current = loaded
        }
        let source = SecretSource.keychain(service: SecretKeychain.service, account: name)
        var updated = current
        if let existing = current.secret(named: name) {
            guard existing.source == source else {
                return .failure(CommandFailure(
                    "\(name) reads from \(existing.source.locator); rv secrets set only stores values it reads "
                        + "from \(SecretKeychain.service)"))
            }
            guard definition == nil, agents.isEmpty, description == nil else {
                return .failure("\(name) is already defined; edit secrets.json to change its delivery")
            }
        } else {
            guard let definition else {
                return .failure("\(name) is new: pass --gateway URL --base-url-env VAR, or --environment")
            }
            let delivery: SecretDelivery
            switch definition {
            case .environment:
                delivery = .environment
            case .gateway(let upstream, let baseURLEnv, let prefix):
                guard let url = URL(string: upstream) else { return .failure("--gateway must be an https URL") }
                delivery = .gateway(SecretGatewayBinding(upstream: url, baseURLEnv: baseURLEnv, placeholderPrefix: prefix))
            }
            updated.secrets.append(SecretDefinition(
                name: name, description: description, agents: agents.isEmpty ? nil : agents,
                source: source, delivery: delivery))
            switch SecretsConfiguration.decode(updated.encoded()) {
            case .failure(let error): return .failure(CommandFailure(error.message))
            case .success(let normalized): updated = normalized
            }
        }
        if let reason = environment.managed.invalidReason {
            return .failure(CommandFailure("organization policy is invalid: \(reason)"))
        }
        if let definition = updated.secret(named: name),
            let reason = SecretOrganizationRules.violation(definition, policy: environment.managed.policy)
        {
            return .failure(CommandFailure("organization policy: \(reason)"))
        }
        guard environment.keychain.store(SecretKeychain.service, name, value) else {
            return .failure("could not store \(name) in the Keychain")
        }
        if updated != current, case .failure(let error) = updated.write(configDirectory: environment.configDirectory) {
            return .failure(CommandFailure(error.message))
        }
        guard let secret = updated.secret(named: name) else { return .failure("\(name) was not saved") }
        var text = "Stored \(name) in the Keychain (\(SecretKeychain.service)). Delivery: \(secret.delivery.summary).\n"
        let users = profiles(environment).filter { $0.secrets.contains(name) }.map(\.id)
        if users.isEmpty {
            text += "Add \"\(name)\" to a profile's \"secrets\" in runtime-resources.json to use it.\n"
        } else {
            text += "Used by profiles: \(users.joined(separator: ", ")).\n"
        }
        return .success(text)
    }

    static func remove(name: String, environment: SecretsEnvironment) -> Result<String, CommandFailure> {
        let current: SecretsConfiguration
        switch configuration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): current = loaded
        }
        let ownSource = SecretSource.keychain(service: SecretKeychain.service, account: name)
        let existing = current.secret(named: name)
        var lines: [String] = []
        if existing == nil || existing?.source == ownSource {
            guard environment.keychain.delete(SecretKeychain.service, name) else {
                return .failure("could not delete \(name) from the Keychain")
            }
            lines.append("Deleted \(name) from the Keychain (\(SecretKeychain.service)).")
        } else if let existing {
            lines.append("Left the value in place at \(existing.source.locator).")
        }
        if existing != nil {
            var updated = current
            updated.secrets.removeAll { $0.name == name }
            if case .failure(let error) = updated.write(configDirectory: environment.configDirectory) {
                return .failure(CommandFailure(error.message))
            }
            lines.append("Removed \(name) from secrets.json.")
        }
        let users = profiles(environment).filter { $0.secrets.contains(name) }.map(\.id)
        if users.isEmpty == false {
            lines.append("warning: profiles \(users.joined(separator: ", ")) still list \(name); their launches will fail until you remove it.")
        }
        return .success(lines.joined(separator: "\n") + "\n")
    }

    struct ScanReport: Encodable, Equatable {
        var findings: [SecretLeakFinding]
        var skipped: [String]
    }

    static func scan(
        root: URL, configuration: SecretsConfiguration, environment: SecretsEnvironment
    ) -> ScanReport {
        var values: [(name: String, value: SecretValue)] = []
        var skipped: [String] = []
        for secret in configuration.secrets {
            switch environment.resolver.resolve(secret.source) {
            case .success(let value): values.append((secret.name, value))
            case .failure(let error): skipped.append("\(secret.name): \(error.message)")
            }
        }
        return ScanReport(findings: SecretLeakScanner.scan(root: root, secrets: values), skipped: skipped)
    }

    static func scanText(_ report: ScanReport) -> String {
        var lines = report.findings.map { "\($0.path):\($0.line)  \($0.secret)" }
        if report.findings.isEmpty { lines.append("No secret values found.") }
        lines += report.skipped.map { "could not check \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    struct DescribeRow: Encodable, Equatable {
        var name: String
        var description: String?
        var type: String?
        var delivery: String
        var source: String
    }

    struct DescribeReport: Encodable, Equatable {
        var secrets: [DescribeRow]
    }

    /// Names, descriptions, types, and delivery. No values and no provider locators.
    static func describe(_ configuration: SecretsConfiguration) -> DescribeReport {
        DescribeReport(secrets: configuration.secrets.map { secret in
            DescribeRow(
                name: secret.name, description: secret.description, type: secret.type,
                delivery: secret.delivery == .environment ? "environment" : "gateway",
                source: secret.source.kind)
        })
    }

    static func describeText(_ report: DescribeReport) -> String {
        guard report.secrets.isEmpty == false else { return "No secrets configured.\n" }
        return report.secrets.map { row in
            var lines = ["\(row.name)  \(row.source)  \(row.delivery)"]
            if let type = row.type { lines.append("  type: \(type)") }
            if let description = row.description { lines.append("  \(description)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n") + "\n"
    }

    static func importVarlock(
        path: URL, dryRun: Bool, environment: SecretsEnvironment
    ) -> Result<String, CommandFailure> {
        guard let data = try? Data(contentsOf: path), data.count <= VarlockSchema.maximumBytes else {
            return .failure("could not read \(path.path) (limit 1 MiB)")
        }
        guard let text = String(data: data, encoding: .utf8) else { return .failure("\(path.path) is not UTF-8") }
        let imported: VarlockImportPlan
        switch VarlockSchema.plan(text) {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success(let plan): imported = plan
        }
        let current: SecretsConfiguration
        switch configuration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): current = loaded
        }
        var lines = imported.notes.map { $0 }
        let fresh = imported.secrets.filter { secret in
            if current.secret(named: secret.name) != nil {
                lines.append("skip \(secret.name): secrets.json already defines it")
                return false
            }
            lines.append("import \(secret.name): \(secret.source.kind)\(secret.type.map { " (type \($0))" } ?? "")")
            return true
        }
        guard fresh.isEmpty == false else {
            return .success((lines + ["nothing to import"]).joined(separator: "\n") + "\n")
        }
        if dryRun { return .success((lines + ["dry run: nothing written"]).joined(separator: "\n") + "\n") }
        var updated = current
        updated.secrets += fresh
        if let reason = environment.managed.invalidReason {
            return .failure("organization policy is invalid: \(reason); nothing imported")
        }
        for secret in fresh {
            if let reason = SecretOrganizationRules.violation(secret, policy: environment.managed.policy) {
                return .failure("organization policy: \(reason); nothing imported")
            }
        }
        switch updated.write(configDirectory: environment.configDirectory) {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success:
            lines.append("wrote secrets.json (\(fresh.count) \(fresh.count == 1 ? "secret" : "secrets"); delivery environment)")
            return .success(lines.joined(separator: "\n") + "\n")
        }
    }

    static func hookRun(workTree: URL, environment: SecretsEnvironment) -> Result<(text: String, failed: Bool), CommandFailure> {
        let configuration: SecretsConfiguration
        switch self.configuration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): configuration = loaded
        }
        var values: [(name: String, value: SecretValue)] = []
        var skipped: [String] = []
        for secret in configuration.secrets {
            switch environment.resolver.resolve(secret.source) {
            case .success(let value): values.append((secret.name, value))
            case .failure(let error): skipped.append("could not check \(secret.name): \(error.message)")
            }
        }
        let findings: [SecretLeakFinding]
        switch SecretGitHook.scan(workTree: workTree, secrets: values) {
        case .failure(let reason): return .failure(CommandFailure(reason.message))
        case .success(let found): findings = found
        }
        var lines = findings.map { "\($0.path):\($0.line):\($0.secret)" }
        if findings.isEmpty { lines.append("No secret values in staged files.") }
        lines += skipped
        return .success((lines.joined(separator: "\n") + "\n", findings.isEmpty == false))
    }

    static func rvPath() -> String {
        let invoked = CommandLine.arguments.first ?? "rv"
        if invoked.contains("/") { return URL(fileURLWithPath: invoked).standardizedFileURL.path }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(invoked).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return invoked
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}\n" }
        return text + "\n"
    }

    /// The secret value: hidden prompt on a terminal, otherwise all of stdin
    /// minus trailing newlines.
    static func readValue(name: String, stdinIsTTY: Bool) -> Data? {
        if stdinIsTTY {
            #if canImport(Darwin)
            var buffer = [CChar](repeating: 0, count: SecretValue.maximumBytes + 2)
            guard readpassphrase("Value for \(name): ", &buffer, buffer.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) != nil
            else { return nil }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            for index in buffer.indices { buffer[index] = 0 }
            return Data(bytes)
            #else
            return nil
            #endif
        }
        var data = FileHandle.standardInput.readDataToEndOfFile()
        while let last = data.last, last == 10 || last == 13 { data.removeLast() }
        return data
    }
}

struct Secrets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secrets",
        abstract: "Manage secrets agents use through placeholders.",
        subcommands: [
            SecretsList.self, SecretsCheck.self, SecretsSet.self, SecretsRemove.self, SecretsScan.self,
            SecretsDescribe.self, SecretsImport.self, SecretsHook.self,
        ],
        defaultSubcommand: SecretsList.self
    )
}

struct SecretsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List configured secrets, their sources, and how agents receive them.")

    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "secrets list", format: format)
        let environment = SecretsEnvironment.live(home: try ctx.requireHome())
        switch SecretsRun.configuration(environment) {
        case .failure(let failure):
            try ctx.fail("rv secrets list: \(failure.message)\n")
        case .success(let configuration):
            let report = SecretsRun.list(configuration, profiles: SecretsRun.profiles(environment))
            ctx.writeStdout(ctx.explicitRobot ? SecretsRun.json(report) : SecretsRun.listText(report))
        }
    }
}

struct SecretsCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check", abstract: "Resolve secrets from their providers and show fingerprints, never values.")

    @Argument(help: "Secret names. Default: all.") var names: [String] = []
    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "secrets check", format: format)
        let environment = SecretsEnvironment.live(home: try ctx.requireHome())
        let rows: [SecretsRun.CheckRow]
        switch SecretsRun.configuration(environment).flatMap({
            SecretsRun.check($0, names: names, environment: environment)
        }) {
        case .failure(let failure): try ctx.fail("rv secrets check: \(failure.message)\n")
        case .success(let checked): rows = checked
        }
        let text = ctx.explicitRobot ? SecretsRun.json(rows) : SecretsRun.checkText(rows)
        if rows.allSatisfy(\.ok) {
            ctx.writeStdout(text)
        } else {
            try ctx.emit(stdout: text, exitCode: 1)
        }
    }
}

struct SecretsSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Store a secret value in the Keychain; define it on first use.",
        discussion: """
            The value is read from a hidden prompt, or from stdin when piped. New secrets need a delivery:
              rv secrets set OPENAI_API_KEY --gateway https://api.openai.com/v1 --base-url-env OPENAI_BASE_URL
              printf %s "$TOKEN" | rv secrets set GH_TOKEN --environment
            """
    )

    @Argument(help: "Environment variable name the agent sees.") var name: String
    @Option(help: "https upstream the gateway may send this secret to.") var gateway: String?
    @Option(name: .customLong("base-url-env"), help: "Variable that receives the gateway base URL.")
    var baseURLEnv: String?
    @Option(name: .customLong("placeholder-prefix"), help: "Prefix kept on the placeholder (for SDK format checks).")
    var placeholderPrefix: String = ""
    @Flag(help: "Put the real value in the cage environment instead (weaker).") var environment = false
    @Option(name: .customLong("agent"), help: "Only stage for this agent tag (repeatable).") var agents: [String] = []
    @Option(help: "Short description.") var description: String?

    func validate() throws {
        if environment, gateway != nil { throw ValidationError("pass either --gateway or --environment, not both") }
        if gateway != nil, baseURLEnv == nil { throw ValidationError("--gateway needs --base-url-env") }
        if gateway == nil, baseURLEnv != nil { throw ValidationError("--base-url-env needs --gateway") }
    }

    func run() throws {
        let ctx = CommandContext.current(command: "secrets set", json: false, robot: false, plain: true, noColor: true)
        let environment = SecretsEnvironment.live(home: try ctx.requireHome())
        var definition: SecretsRun.Definition?
        if let gateway, let baseURLEnv {
            definition = .gateway(upstream: gateway, baseURLEnv: baseURLEnv, placeholderPrefix: placeholderPrefix)
        } else if self.environment {
            definition = .environment
        }
        guard let value = SecretsRun.readValue(name: name, stdinIsTTY: isatty(STDIN_FILENO) == 1) else {
            try ctx.fail("rv secrets set: no value read\n")
        }
        switch SecretsRun.set(
            name: name, value: value, definition: definition, agents: agents, description: description,
            environment: environment)
        {
        case .failure(let failure): try ctx.fail("rv secrets set: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}

struct SecretsRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Delete a secret's definition and its rv-stored Keychain value.")

    @Argument var name: String

    func run() throws {
        let ctx = CommandContext.current(command: "secrets remove", json: false, robot: false, plain: true, noColor: true)
        switch SecretsRun.remove(name: name, environment: .live(home: try ctx.requireHome())) {
        case .failure(let failure): try ctx.fail("rv secrets remove: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}

struct SecretsScan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan", abstract: "Find files containing any secret value rv can resolve (exits 1 on findings).")

    @Argument(help: "Directory to scan. Default: current directory.") var path: String?
    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "secrets scan", format: format)
        let environment = SecretsEnvironment.live(home: try ctx.requireHome())
        let root = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            try ctx.fail("rv secrets scan: \(root.path) is not a directory\n")
        }
        let configuration: SecretsConfiguration
        switch SecretsRun.configuration(environment) {
        case .failure(let failure): try ctx.fail("rv secrets scan: \(failure.message)\n")
        case .success(let loaded): configuration = loaded
        }
        let report = SecretsRun.scan(root: root, configuration: configuration, environment: environment)
        let text = ctx.explicitRobot ? SecretsRun.json(report) : SecretsRun.scanText(report)
        if report.findings.isEmpty {
            ctx.writeStdout(text)
        } else {
            try ctx.emit(stdout: text, exitCode: 1)
        }
    }
}

struct SecretsDescribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe",
        abstract: "Show secret names, descriptions, types, and delivery. Never values.")

    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "secrets describe", format: format)
        let environment = SecretsEnvironment.live(home: try ctx.requireHome())
        switch SecretsRun.configuration(environment) {
        case .failure(let failure): try ctx.fail("rv secrets describe: \(failure.message)\n")
        case .success(let configuration):
            let report = SecretsRun.describe(configuration)
            ctx.writeStdout(ctx.explicitRobot ? SecretsRun.json(report) : SecretsRun.describeText(report))
        }
    }
}

struct SecretsImport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Add secrets from a Varlock .env.schema. Literal values are not copied.")

    @Option(name: .customLong("varlock"), help: "Path to a .env.schema file.") var varlock: String
    @Flag(name: .customLong("dry-run"), help: "Show what would be imported.") var dryRun = false

    func run() throws {
        let ctx = CommandContext.current(command: "secrets import", json: false, robot: false, plain: true, noColor: true)
        let environment = SecretsEnvironment.live(home: try ctx.requireHome())
        let path = URL(fileURLWithPath: varlock).standardizedFileURL
        switch SecretsRun.importVarlock(path: path, dryRun: dryRun, environment: environment) {
        case .failure(let failure): try ctx.fail("rv secrets import: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}

struct SecretsHook: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Git pre-commit hook that scans staged content for secret values.",
        subcommands: [SecretsHookInstall.self, SecretsHookUninstall.self, SecretsHookRun.self])
}

struct SecretsHookInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Install the pre-commit hook in this repository. Safe to run again.")

    func run() throws {
        let ctx = CommandContext.current(command: "secrets hook install", json: false, robot: false, plain: true, noColor: true)
        let workTree = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        switch SecretGitHook.install(workTree: workTree, rvPath: SecretsRun.rvPath()) {
        case .failure(let error): try ctx.fail("rv secrets hook install: \(error.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}

struct SecretsHookUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall", abstract: "Remove rv's pre-commit hook and restore the previous one.")

    func run() throws {
        let ctx = CommandContext.current(command: "secrets hook uninstall", json: false, robot: false, plain: true, noColor: true)
        let workTree = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        switch SecretGitHook.uninstall(workTree: workTree) {
        case .failure(let error): try ctx.fail("rv secrets hook uninstall: \(error.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}

struct SecretsHookRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Scan staged files. The installed hook runs this.")

    func run() throws {
        let ctx = CommandContext.current(command: "secrets hook run", json: false, robot: false, plain: true, noColor: true)
        let environment = SecretsEnvironment.live(home: try ctx.requireHome())
        let workTree = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        switch SecretsRun.hookRun(workTree: workTree, environment: environment) {
        case .failure(let failure): try ctx.fail("rv secrets hook run: \(failure.message)\n")
        case .success(let result):
            if result.failed { try ctx.emit(stdout: result.text, exitCode: 1) }
            else { ctx.writeStdout(result.text) }
        }
    }
}

struct CommandFailure: Error, Equatable, ExpressibleByStringInterpolation {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    init(stringLiteral value: String) {
        message = value
    }
}
