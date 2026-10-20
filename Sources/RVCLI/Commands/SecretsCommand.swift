import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVHistory
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
        /// Value lives in a `.env` file rv reads at lease time.
        var fileBacked: Bool
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

    /// Delivery for `rv secrets set`: explicit flags win; otherwise a new
    /// secret with a well-known name inherits its curated gateway (an
    /// explicit --placeholder-prefix still overrides the curated prefix).
    /// Existing secrets and unknown names resolve to nil, preserving the
    /// established update-value and pass-a-delivery behaviors.
    static func definitionForSet(
        name: String, isNew: Bool, gateway: String?, baseURLEnv: String?,
        placeholderPrefix: String, environment: Bool
    ) -> (definition: Definition?, note: String?) {
        if let gateway, let baseURLEnv {
            return (
                .gateway(upstream: gateway, baseURLEnv: baseURLEnv, placeholderPrefix: placeholderPrefix), nil)
        }
        if environment {
            return (.environment, nil)
        }
        guard isNew, let known = KnownSecretDefaults.gateway(for: name) else { return (nil, nil) }
        let prefix = placeholderPrefix.isEmpty ? known.placeholderPrefix : placeholderPrefix
        let definition = Definition.gateway(
            upstream: known.upstream, baseURLEnv: known.baseURLEnv, placeholderPrefix: prefix)
        let note =
            "Using known defaults for \(DisplayedText.field(name)): gateway \(known.upstream) via $\(known.baseURLEnv).\n"
        return (definition, note)
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
                weaker: secret.delivery == .environment && secret.source.kind != "dotenv",
                fileBacked: secret.source.kind == "dotenv"
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
                + "or bind an existing .env by reference (values stay in .env):\n"
                + "  rv secrets import --dotenv .env\n"
        }
        let width = report.secrets.map(\.name.count).max() ?? 0
        var lines = report.secrets.map { row -> String in
            var line = row.name.padding(toLength: width, withPad: " ", startingAt: 0)
                + "  \(row.source)  \(row.delivery)"
            line += "  profiles: \(row.profiles.isEmpty ? "-" : row.profiles.joined(separator: ","))"
            if let agents = row.agents { line += "  agents: \(agents.joined(separator: ","))" }
            if row.weaker { line += "  [weaker]" }
            if row.fileBacked { line += "  [file-backed]" }
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
                    return .failure("\(DisplayedText.field(name)) is not defined in secrets.json")
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
                var message =
                    "\(DisplayedText.field(name)) reads from \(existing.source.locator); rv secrets set only stores values it reads "
                    + "from \(SecretKeychain.service)"
                if existing.source.kind == "dotenv" {
                    message += "\nuse `rv secrets harden \(name)` to move this value into the Keychain"
                }
                return .failure(CommandFailure(message))
            }
            guard definition == nil, agents.isEmpty, description == nil else {
                return .failure("\(DisplayedText.field(name)) is already defined; edit secrets.json to change its delivery")
            }
        } else {
            guard let definition else {
                return .failure(CommandFailure(
                    "\(DisplayedText.field(name)) is new: pass --gateway URL --base-url-env VAR, or --environment; "
                        + "to bind a value already in a .env file instead, use `rv secrets import --dotenv <file>`"))
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
            return .failure("could not store \(DisplayedText.field(name)) in the Keychain")
        }
        if updated != current, case .failure(let error) = updated.write(configDirectory: environment.configDirectory) {
            return .failure(CommandFailure(error.message))
        }
        guard let secret = updated.secret(named: name) else { return .failure("\(DisplayedText.field(name)) was not saved") }
        var text = "Stored \(DisplayedText.field(name)) in the Keychain (\(SecretKeychain.service)). Delivery: \(secret.delivery.summary).\n"
        let users = profiles(environment).filter { $0.secrets.contains(name) }.map(\.id)
        if users.isEmpty {
            text += "Add \"\(DisplayedText.field(name))\" to a profile's \"secrets\" in runtime-resources.json to use it.\n"
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
                return .failure("could not delete \(DisplayedText.field(name)) from the Keychain")
            }
            lines.append("Deleted \(DisplayedText.field(name)) from the Keychain (\(SecretKeychain.service)).")
        } else if let existing {
            lines.append("Left the value in place at \(existing.source.locator).")
        }
        if existing != nil {
            var updated = current
            updated.secrets.removeAll { $0.name == name }
            if case .failure(let error) = updated.write(configDirectory: environment.configDirectory) {
                return .failure(CommandFailure(error.message))
            }
            lines.append("Removed \(DisplayedText.field(name)) from secrets.json.")
        }
        let users = profiles(environment).filter { $0.secrets.contains(name) }.map(\.id)
        if users.isEmpty == false {
            lines.append("warning: profiles \(users.joined(separator: ", ")) still list \(DisplayedText.field(name)); their launches will fail until you remove it.")
        }
        return .success(lines.joined(separator: "\n") + "\n")
    }

    /// Moves dotenv-bound values into the Keychain and rebinds their
    /// definitions. Value first, config second: every Keychain write and
    /// read-back verification happens before the single secrets.json write,
    /// so a failure leaves definitions untouched (orphaned Keychain copies
    /// are benign and overwritten on retry). By decision D1 this works
    /// under a dotenv-deny policy (carve-out, audited); it still requires
    /// keychain to be an allowed source. rv never edits the `.env`.
    static func harden(
        names: [String], all: Bool, environment: SecretsEnvironment
    ) -> Result<(text: String, failed: Bool), CommandFailure> {
        let current: SecretsConfiguration
        switch configuration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): current = loaded
        }
        if let reason = environment.managed.invalidReason {
            return .failure(CommandFailure("organization policy is invalid: \(reason)"))
        }
        if environment.managed.policy?.allowsSecretSource("keychain") == false {
            return .failure(CommandFailure(
                "organization policy: keychain sources are not allowed, so there is nowhere to harden to"))
        }
        let selected = all ? current.secrets.map(\.name) : names
        var lines: [String] = []
        // Success wording is buffered: if a later name blocks the write,
        // nothing was rebound and the rotation checklists must not print.
        var successLines: [String] = []
        var failed = false
        var rebound: [String: SecretDefinition] = [:]
        var originals: [String: SecretDefinition] = [:]
        var storedValues: [String: SecretValue] = [:]
        var events: [AuditEvent] = []
        for name in selected {
            guard let definition = current.secret(named: name) else {
                lines.append("\(DisplayedText.field(name)) is not defined in secrets.json")
                failed = true
                continue
            }
            guard case .dotenv(let path, let variable) = definition.source else {
                if all {
                    lines.append("skip \(name): reads from \(definition.source.locator) (not dotenv; nothing to harden)")
                } else {
                    lines.append("\(DisplayedText.field(name)) reads from \(definition.source.locator); only dotenv sources can be hardened")
                    failed = true
                }
                continue
            }
            let target = SecretSource.keychain(service: SecretKeychain.service, account: name)
            if current.secrets.contains(where: { $0.name != name && $0.source == target }) {
                lines.append(
                    "could not harden \(name): another secret already reads from \(target.locator); "
                        + "storing would overwrite its value")
                failed = true
                continue
            }
            let value: SecretValue
            switch environment.resolver.resolve(definition.source) {
            case .failure(let error):
                lines.append("could not harden \(name): \(error.message)")
                failed = true
                continue
            case .success(let resolved): value = resolved
            }
            guard environment.keychain.store(SecretKeychain.service, name, Data(value.revealed())) else {
                lines.append("could not harden \(name): could not store \(DisplayedText.field(name)) in the Keychain")
                failed = true
                continue
            }
            switch environment.resolver.resolve(target) {
            case .success(let readBack) where readBack == value:
                break
            default:
                lines.append("could not harden \(name): the stored Keychain value does not match the .env value; binding left unchanged")
                failed = true
                continue
            }
            var hardened = definition
            hardened.source = target
            rebound[name] = hardened
            originals[name] = definition
            storedValues[name] = value
            events.append(AuditEvent(
                time: Date(), kind: .secretUse, decision: .info, subject: name,
                reason: "dotenv value moved to the Keychain", source: "secrets-harden",
                detail: [
                    "event": "hardened",
                    "from": definition.source.locator,
                    "to": target.locator,
                    "verified": "true",
                ]))
            successLines.append(
                "hardened \(name): \(definition.source.locator) -> \(target.locator) (delivery unchanged: \(definition.delivery.kind); stored value verified)")
            if let reason = SecretOrganizationRules.violation(hardened, policy: environment.managed.policy) {
                successLines.append(
                    "warning: organization policy: \(reason); \(name) still will not stage until that is resolved")
            }
            successLines.append("rotation checklist for \(name):")
            successLines.append("  - rotate the value at the provider (the old value is still live in .env)")
            successLines.append("  - remove the \(variable) line from \(DisplayedText.field(path)) (rv never edits .env)")
            successLines.append("  - until removed, `rv secrets scan` will keep flagging the unrotated .env")
        }
        if failed, rebound.isEmpty == false {
            // All-or-nothing: a failed name blocks the config write. Values
            // already copied to the Keychain are benign; a retry overwrites.
            // Keep the .env lines: the bindings still resolve from them.
            lines.append(
                "nothing rebound: \(rebound.count) value\(rebound.count == 1 ? "" : "s") copied to the Keychain but still bound to .env; "
                    + "fix the failures and run harden again (do not remove any .env lines yet)")
            return .success((lines.joined(separator: "\n") + "\n", true))
        }
        if rebound.isEmpty == false {
            // Re-verify against a fresh load immediately before the single
            // write: a config edit or a .env change since the values were
            // copied must not be silently overwritten or rebound stale.
            let reloaded: SecretsConfiguration
            switch configuration(environment) {
            case .failure(let failure): return .failure(failure)
            case .success(let loaded): reloaded = loaded
            }
            for (name, original) in originals {
                guard reloaded.secret(named: name) == original else {
                    lines.append(
                        "nothing rebound: \(name) changed in secrets.json during harden; run harden again "
                            + "(do not remove any .env lines yet)")
                    return .success((lines.joined(separator: "\n") + "\n", true))
                }
                guard case .success(let fresh) = environment.resolver.resolve(original.source),
                    fresh == storedValues[name]
                else {
                    lines.append(
                        "nothing rebound: the .env value for \(name) changed during harden; run harden again "
                            + "(do not remove any .env lines yet)")
                    return .success((lines.joined(separator: "\n") + "\n", true))
                }
            }
            var updated = reloaded
            updated.secrets = updated.secrets.map { rebound[$0.name] ?? $0 }
            if case .failure(let error) = updated.write(configDirectory: environment.configDirectory) {
                return .failure(CommandFailure(error.message))
            }
            lines += successLines
            // The migration carve-out is only accountable if its audit event
            // landed; a lost append is a loud failure, never silent.
            var auditFailed = false
            for event in events {
                if AuditLog.append(event, configDirectory: environment.configDirectory) == false {
                    auditFailed = true
                }
            }
            if auditFailed {
                lines.append(
                    "error: bindings were rebound but the harden audit event could not be recorded; "
                        + "check the audit log under \(DisplayedText.field(environment.configDirectory.path))")
                return .success((lines.joined(separator: "\n") + "\n", true))
            }
        } else {
            lines += successLines
        }
        if lines.isEmpty { lines.append("no dotenv-bound secrets to harden") }
        return .success((lines.joined(separator: "\n") + "\n", failed))
    }

    struct ScanReport: Encodable, Equatable {
        var findings: [SecretLeakFinding]
        /// Findings inside the very `.env` that secret is bound to. Reported
        /// separately and never fail the gate; any other secret's value in
        /// the same file, or a copy elsewhere, still flags.
        var origins: [SecretLeakFinding] = []
        /// Set when nothing could be checked (invalid organization policy).
        /// A scan that checked nothing must not pass the gate.
        var blocked: String?
        var skipped: [String]

        /// The gate fails on findings, on a blocked scan, and on any secret
        /// that could not be checked: a partial scan is not a clean scan.
        var failed: Bool {
            blocked != nil || findings.isEmpty == false || skipped.isEmpty == false
        }
    }

    static func scan(
        root: URL, configuration: SecretsConfiguration, environment: SecretsEnvironment
    ) -> ScanReport {
        if let reason = environment.managed.invalidReason {
            return ScanReport(
                findings: [], blocked: "organization policy is invalid: \(reason); nothing was checked",
                skipped: [])
        }
        var values: [(name: String, value: SecretValue)] = []
        var skipped: [String] = []
        for secret in configuration.secrets {
            if let reason = SecretOrganizationRules.violation(secret, policy: environment.managed.policy) {
                skipped.append("\(secret.name): organization policy: \(reason)")
                continue
            }
            switch environment.resolver.resolve(secret.source) {
            case .success(let value): values.append((secret.name, value))
            case .failure(let error): skipped.append("\(secret.name): \(error.message)")
            }
        }
        let found = SecretLeakScanner.scan(root: root, secrets: values)
        let resolvedRoot = root.resolvingSymlinksInPath().path
        var boundPaths: [String: String] = [:]
        for secret in configuration.secrets {
            if case .dotenv(let path, _) = secret.source, let canonical = DotenvLiveReader.canonicalPath(path) {
                boundPaths[secret.name] = canonical
            }
        }
        var findings: [SecretLeakFinding] = []
        var origins: [SecretLeakFinding] = []
        for finding in found {
            let absolute = finding.path.hasPrefix("/") ? finding.path : resolvedRoot + "/" + finding.path
            if let bound = boundPaths[finding.secret], DotenvLiveReader.canonicalPath(absolute) == bound {
                origins.append(finding)
            } else {
                findings.append(finding)
            }
        }
        return ScanReport(findings: findings, origins: origins, skipped: skipped)
    }

    /// Human refusal when `rv secrets scan` is pointed at a file, not a directory.
    static func scanNotADirectory(_ path: String) -> String {
        "\(DisplayedText.field(path)) is not a directory"
    }

    static func scanText(_ report: ScanReport) -> String {
        if let blocked = report.blocked { return blocked + "\n" }
        var lines: [String] = []
        if report.origins.isEmpty == false {
            lines.append("origin files (bound .env sources; not failures):")
            var byPath: [String: Set<String>] = [:]
            for origin in report.origins { byPath[origin.path, default: []].insert(origin.secret) }
            for path in byPath.keys.sorted() {
                let count = byPath[path]?.count ?? 0
                lines.append("  \(DisplayedText.field(path)) (\(count) secret\(count == 1 ? "" : "s") bound)")
            }
        }
        lines += report.findings.map { "\(DisplayedText.field($0.path)):\($0.line)  \($0.secret)" }
        if report.findings.isEmpty {
            lines.append(report.skipped.isEmpty
                ? "No secret values found."
                : "No secret values found, but not every secret could be checked.")
        }
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

    /// What a dotenv import would bind, after every pre-filter. Shared by
    /// `rv secrets import --dotenv` and `rv init --dotenv` so both doors
    /// review and write the same thing.
    struct DotenvCandidates {
        var storedPath: String
        var fresh: [SecretDefinition]
        /// Names already defined (any source) that appear in the file.
        var alreadyDefined: [String]
        /// Already-defined names bound to exactly this file and variable:
        /// the only pre-existing names an ingestion may wire, so one
        /// project's profile never stages another project's value.
        var alreadyDefinedHere: [String] = []
        var lines: [String]
    }

    static func dotenvCandidates(
        path: URL, current: SecretsConfiguration, hostEnvironment: [String: String]
    ) -> Result<DotenvCandidates, CommandFailure> {
        let snapshot: DotenvFileSnapshot
        switch DotenvLiveReader.read(path: path.standardizedFileURL.path) {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success(let loaded): snapshot = loaded
        }
        // Bind the canonical path the trust checks just validated. The
        // resolver refuses a binding whose path later resolves elsewhere,
        // so a retargeted symlink component cannot substitute files.
        let storedPath = snapshot.canonicalPath
        let parsed: DotenvParse
        switch DotenvFile.parse(snapshot.data) {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success(let loaded): parsed = loaded
        }
        if let malformedLine = parsed.malformedLine {
            return .failure(CommandFailure(
                "dotenv file \(DisplayedText.field(snapshot.canonicalPath)) line \(malformedLine) is not a NAME=VALUE assignment; nothing imported"))
        }
        var lines = parsed.lintNotes
        var fresh: [SecretDefinition] = []
        var alreadyDefined: [String] = []
        var alreadyDefinedHere: [String] = []
        let exported = Set(current.secrets.flatMap { secret -> [String] in
            if case .gateway(let binding) = secret.delivery { return [secret.name, binding.baseURLEnv] }
            return [secret.name]
        })
        for entry in parsed.entries {
            let name = entry.name
            if parsed.duplicates.contains(name) {
                lines.append("skip \(name): duplicate variable in file")
                continue
            }
            if let existing = current.secret(named: name) {
                lines.append("skip \(name): already bound to \(existing.source.locator)")
                alreadyDefined.append(name)
                if case .dotenv(let boundPath, let boundVariable) = existing.source,
                    boundPath == storedPath, boundVariable == name
                {
                    alreadyDefinedHere.append(name)
                }
                continue
            }
            if SecretsConfiguration.isVariableName(name) == false {
                lines.append("skip \(name): not an environment variable name")
                continue
            }
            if SecretsConfiguration.isReservedVariable(name) {
                lines.append("skip \(name): reserved variable")
                continue
            }
            if ContainedEnvironmentPolicy.isLoaderOrInterpreterVariableName(name) {
                lines.append("skip \(name): loader/interpreter variable is never bound from a file")
                continue
            }
            if exported.contains(name) {
                lines.append("skip \(name): already exported by another secret")
                continue
            }
            if hostEnvironment[name] != nil {
                lines.append("skip \(name): already defined in this project's environment")
                continue
            }
            if entry.value.isEmpty {
                lines.append("skip \(name): empty value cannot stage")
                continue
            }
            if entry.value.utf8.count > 8_192 {
                lines.append("skip \(name): value exceeds the 8 KiB environment limit")
                continue
            }
            if current.secrets.count + fresh.count >= SecretsConfiguration.maximumSecrets {
                lines.append("skip \(name): secrets.json already defines the maximum of \(SecretsConfiguration.maximumSecrets) secrets")
                continue
            }
            fresh.append(SecretDefinition(
                name: name, source: .dotenv(path: storedPath, variable: name), delivery: .environment))
            lines.append("import \(name): dotenv (delivery environment)")
        }
        return .success(DotenvCandidates(
            storedPath: storedPath, fresh: fresh, alreadyDefined: alreadyDefined,
            alreadyDefinedHere: alreadyDefinedHere, lines: lines))
    }

    /// Binds `.env` variables by reference. Values stay in the file; the
    /// file is read through the same trust checks the lease applies, and
    /// organization policy is checked before the dry-run return.
    static func importDotenv(
        path: URL, dryRun: Bool, environment: SecretsEnvironment,
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<String, CommandFailure> {
        let current: SecretsConfiguration
        switch configuration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): current = loaded
        }
        let candidates: DotenvCandidates
        switch dotenvCandidates(path: path, current: current, hostEnvironment: hostEnvironment) {
        case .failure(let failure): return .failure(failure)
        case .success(let built): candidates = built
        }
        if let reason = environment.managed.invalidReason {
            return .failure("organization policy is invalid: \(reason); nothing imported")
        }
        for secret in candidates.fresh {
            if let reason = SecretOrganizationRules.violation(secret, policy: environment.managed.policy) {
                return .failure("organization policy: \(reason); nothing imported")
            }
        }
        var lines = ["storing absolute path: \(DisplayedText.field(candidates.storedPath))"] + candidates.lines
        let gitLine = gitIgnoreStatus(path: candidates.storedPath)
        guard candidates.fresh.isEmpty == false else {
            return .success((lines + [gitLine, "nothing to import"]).joined(separator: "\n") + "\n")
        }
        if dryRun {
            return .success((lines + [gitLine, "dry run: nothing written"]).joined(separator: "\n") + "\n")
        }
        var updated = current
        updated.secrets += candidates.fresh
        switch updated.write(configDirectory: environment.configDirectory) {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success:
            lines.append(
                "wrote secrets.json (\(candidates.fresh.count) \(candidates.fresh.count == 1 ? "secret" : "secrets"); delivery environment)")
            lines.append(gitLine)
            return .success(lines.joined(separator: "\n") + "\n")
        }
    }

    /// Informational only; never fails an import.
    static func gitIgnoreStatus(path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory, "check-ignore", "-q", path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "git: not a work tree (skipped)"
        }
        switch process.terminationStatus {
        case 0: return "git: .env is ignored (check-ignore clean)"
        case 1: return "git: .env is NOT ignored; it may be committed"
        default: return "git: not a work tree (skipped)"
        }
    }

    static func hookRun(workTree: URL, environment: SecretsEnvironment) -> Result<(text: String, failed: Bool), CommandFailure> {
        let configuration: SecretsConfiguration
        switch self.configuration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): configuration = loaded
        }
        if let reason = environment.managed.invalidReason {
            return .failure(CommandFailure("organization policy is invalid: \(reason); nothing was checked"))
        }
        var values: [(name: String, value: SecretValue)] = []
        var skipped: [String] = []
        for secret in configuration.secrets {
            if let reason = SecretOrganizationRules.violation(secret, policy: environment.managed.policy) {
                skipped.append("could not check \(secret.name): organization policy: \(reason)")
                continue
            }
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
        if findings.isEmpty {
            lines.append(skipped.isEmpty
                ? "No secret values in staged files."
                : "No secret values in staged files, but not every secret could be checked.")
        }
        lines += skipped
        // A commit gate that could not check a secret must not pass it.
        return .success((lines.joined(separator: "\n") + "\n", findings.isEmpty == false || skipped.isEmpty == false))
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

    /// Robot JSON for `rv secrets`. `JSONEncoder` already writes ESC as
    /// `\u001b`. U+2028, U+2029, and U+202E stay raw unless they are replaced
    /// after encoding. The result is still valid JSON. `json` itself is unchanged.
    static func robotJSON<T: Encodable>(_ value: T) -> String {
        var text = json(value)
        let scalars: [(Character, String)] = [
            ("\u{2028}", "\\u2028"),
            ("\u{2029}", "\\u2029"),
            ("\u{202E}", "\\u202e"),
        ]
        for (scalar, escaped) in scalars {
            text = text.replacingOccurrences(of: String(scalar), with: escaped)
        }
        return text
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
        abstract: "Manage secrets agents use through placeholders, including .env-backed ones.",
        subcommands: [
            SecretsList.self, SecretsCheck.self, SecretsSet.self, SecretsRemove.self, SecretsScan.self,
            SecretsDescribe.self, SecretsImport.self, SecretsHarden.self, SecretsHook.self,
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
            ctx.writeStdout(ctx.explicitRobot ? SecretsRun.robotJSON(report) : SecretsRun.listText(report))
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
        let text = ctx.explicitRobot ? SecretsRun.robotJSON(rows) : SecretsRun.checkText(rows)
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
            The value is read from a hidden prompt, or from stdin when piped. Well-known names
            (OPENAI_API_KEY, ANTHROPIC_API_KEY, STRIPE_SECRET_KEY, GITHUB_TOKEN, GH_TOKEN) default
            to their gateway; anything else needs a delivery:
              rv secrets set OPENAI_API_KEY --resource-profile main
              rv secrets set ACME_KEY --gateway https://api.acme.com --base-url-env ACME_BASE_URL
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
    @Option(name: .customLong("resource-profile"), help: "Wire the secret into this runtime profile (see `rv init`).")
    var profile: String?

    func validate() throws {
        if environment, gateway != nil { throw ValidationError("pass either --gateway or --environment, not both") }
        if gateway != nil, baseURLEnv == nil { throw ValidationError("--gateway needs --base-url-env") }
        if gateway == nil, baseURLEnv != nil { throw ValidationError("--base-url-env needs --gateway") }
    }

    func run() throws {
        let ctx = CommandContext.current(command: "secrets set", json: false, robot: false, plain: true, noColor: true)
        let environment = SecretsEnvironment.live(home: try ctx.requireHome())
        let configuration: SecretsConfiguration
        switch SecretsRun.configuration(environment) {
        case .failure(let failure): try ctx.fail("rv secrets set: \(failure.message)\n")
        case .success(let loaded): configuration = loaded
        }
        let isNew = configuration.secret(named: name) == nil
        let resolved = SecretsRun.definitionForSet(
            name: name, isNew: isNew, gateway: gateway, baseURLEnv: baseURLEnv,
            placeholderPrefix: placeholderPrefix, environment: self.environment)
        let definition = resolved.definition
        let inferredNote = resolved.note
        if let profile {
            switch RuntimeResourcePolicyStore.load(from: environment.configDirectory) {
            case .failure(let error):
                try ctx.fail("rv secrets set: \(RuntimeResourcePolicyFile.message(error))\n")
            case .success(let policy):
                if policy.profiles.contains(where: { $0.id == profile }) == false {
                    try ctx.fail(
                        "rv secrets set: profile \(DisplayedText.field(profile)) does not exist; run `rv init` to create it\n")
                }
            }
        }
        guard let value = SecretsRun.readValue(name: name, stdinIsTTY: isatty(STDIN_FILENO) == 1) else {
            try ctx.fail("rv secrets set: no value read\n")
        }
        switch SecretsRun.set(
            name: name, value: value, definition: definition, agents: agents, description: description,
            environment: environment)
        {
        case .failure(let failure): try ctx.fail("rv secrets set: \(failure.message)\n")
        case .success(var text):
            if let inferredNote { text = inferredNote + text }
            if let profile {
                switch InitRun.attachSecret(
                    name, profileID: profile, configDirectory: environment.configDirectory)
                {
                case .failure(let failure):
                    text += "warning: stored but not wired into profile \(DisplayedText.field(profile)): \(failure.message)\n"
                case .success(true):
                    text += "Wired \(DisplayedText.field(name)) into profile \(DisplayedText.field(profile)).\n"
                case .success(false):
                    break
                }
            }
            ctx.writeStdout(text)
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
        commandName: "scan", abstract: "Find files containing any secret value rv can resolve (exits 1 on findings or unchecked secrets).")

    @Argument(help: "Directory to scan. Default: current directory.") var path: String?
    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "secrets scan", format: format)
        let environment = SecretsEnvironment.live(home: try ctx.requireHome())
        let root = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            try ctx.fail("rv secrets scan: \(SecretsRun.scanNotADirectory(root.path))\n")
        }
        let configuration: SecretsConfiguration
        switch SecretsRun.configuration(environment) {
        case .failure(let failure): try ctx.fail("rv secrets scan: \(failure.message)\n")
        case .success(let loaded): configuration = loaded
        }
        let report = SecretsRun.scan(root: root, configuration: configuration, environment: environment)
        let text = ctx.explicitRobot ? SecretsRun.robotJSON(report) : SecretsRun.scanText(report)
        if report.failed {
            try ctx.emit(stdout: text, exitCode: 1)
        } else {
            ctx.writeStdout(text)
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
        abstract: "Add secrets from a Varlock .env.schema or a .env file.",
        discussion: """
            --varlock copies provider references from a .env.schema; literal values are not copied.
            --dotenv binds names by reference to a .env file; values stay in the file.
            Pass exactly one of --varlock or --dotenv.
            """)

    @Option(name: .customLong("varlock"), help: "Path to a .env.schema file.") var varlock: String?
    @Option(name: .customLong("dotenv"), help: "Path to a .env file to bind by reference.") var dotenv: String?
    @Flag(name: .customLong("dry-run"), help: "Show what would be imported.") var dryRun = false

    func validate() throws {
        if (varlock == nil) == (dotenv == nil) {
            throw ValidationError("pass exactly one of --varlock <.env.schema> or --dotenv <.env>")
        }
    }

    func run() throws {
        let ctx = CommandContext.current(command: "secrets import", json: false, robot: false, plain: true, noColor: true)
        let environment = SecretsEnvironment.live(home: try ctx.requireHome())
        if let varlock {
            let path = URL(fileURLWithPath: varlock).standardizedFileURL
            switch SecretsRun.importVarlock(path: path, dryRun: dryRun, environment: environment) {
            case .failure(let failure): try ctx.fail("rv secrets import: \(failure.message)\n")
            case .success(let text): ctx.writeStdout(text)
            }
        } else if let dotenv {
            let path = URL(fileURLWithPath: dotenv).standardizedFileURL
            switch SecretsRun.importDotenv(path: path, dryRun: dryRun, environment: environment) {
            case .failure(let failure): try ctx.fail("rv secrets import: \(failure.message)\n")
            case .success(let text): ctx.writeStdout(text)
            }
        }
    }
}

struct SecretsHarden: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "harden",
        abstract: "Move dotenv-bound values into the Keychain and rebind their definitions.",
        discussion: """
            The stored value is read back and compared before anything is
            rebound. Works under a dotenv-deny organization policy (the
            migration path out), but requires keychain to be an allowed
            source. rv never edits the .env: rotate and remove the line
            yourself. On Linux the Keychain is unavailable, so harden fails.
            """)

    @Argument(help: "Secret names to harden.") var names: [String] = []
    @Flag(help: "Harden every dotenv-bound secret.") var all = false

    func validate() throws {
        if all, names.isEmpty == false {
            throw ValidationError("pass secret names, or --all, not both")
        }
        if all == false, names.isEmpty {
            throw ValidationError("pass secret names, or --all")
        }
    }

    func run() throws {
        let ctx = CommandContext.current(command: "secrets harden", json: false, robot: false, plain: true, noColor: true)
        let environment = SecretsEnvironment.live(home: try ctx.requireHome())
        switch SecretsRun.harden(names: names, all: all, environment: environment) {
        case .failure(let failure): try ctx.fail("rv secrets harden: \(failure.message)\n")
        case .success(let result):
            if result.failed { try ctx.emit(stdout: result.text, exitCode: 1) }
            else { ctx.writeStdout(result.text) }
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
