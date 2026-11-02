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
        /// Gateway only: where the placeholder may sit, and allow rules (empty allows any).
        var surfaces: [String]?
        var allow: [String]?
        var expires: String?
        /// Gateway only: how often a running session re-reads the value.
        var refresh: String?
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
        case gateway(
            upstream: String, baseURLEnv: String, placeholderPrefix: String,
            surfaces: Set<GatewaySurface> = GatewaySurface.defaults, allow: [GatewayAllowance] = [])
        case environment
    }

    /// `--expires`: nil keeps what is on file, `none` clears it.
    static func expiry(_ text: String?) -> Result<Date??, CommandFailure> {
        guard let text else { return .success(nil) }
        if text == "none" { return .success(.some(nil)) }
        guard let date = SecretExpiry.parse(text) else {
            return .failure(
                "--expires must be an ISO-8601 date (2026-12-31), a date-time with a zone (2026-12-31T18:00:00Z), or none")
        }
        return .success(.some(date))
    }

    /// `--refresh`: nil keeps what is on file, `none` clears it.
    static func refresh(_ text: String?) -> Result<SecretRefreshInterval??, CommandFailure> {
        guard let text else { return .success(nil) }
        if text == "none" { return .success(.some(nil)) }
        guard let interval = SecretRefreshInterval(text) else {
            return .failure("--refresh must be a whole number of s, m, h, or d from 1m to 30d, such as 15m, or none")
        }
        return .success(.some(interval))
    }

    static let expiryWarningWindow: TimeInterval = 7 * 86_400

    /// A warning for a secret that has expired or expires within a week.
    static func expiryWarning(_ secret: SecretDefinition, now: Date) -> String? {
        guard let expires = secret.expires else { return nil }
        let name = DisplayedText.field(secret.name)
        let date = SecretExpiry.text(expires)
        if expires <= now { return "\(name) expired at \(date); launches that use it fail until it is rotated" }
        guard expires.timeIntervalSince(now) < expiryWarningWindow else { return nil }
        let days = SecretExpiry.daysLeft(expires, now: now)
        let when = days == 0 ? "within a day" : days == 1 ? "in 1 day" : "in \(days) days"
        return "\(name) expires \(when) (\(date)); rotate it with rv secrets set \(name) --expires DATE"
    }

    /// `--allow` values: preset names or `METHODS PATH` rules.
    static func allowances(_ texts: [String]) -> Result<[GatewayAllowance], CommandFailure> {
        guard texts.count <= GatewayAllowance.maximumEntries else {
            return .failure("--allow may be given at most \(GatewayAllowance.maximumEntries) times")
        }
        var allow: [GatewayAllowance] = []
        for text in texts {
            guard let allowance = GatewayAllowance(text) else {
                let presets = GatewayAccessPreset.allCases.map(\.rawValue).joined(separator: ", ")
                return .failure(CommandFailure(
                    "--allow must be a preset (\(presets)) or \"METHODS PATH\" such as \"GET,HEAD /repos/**\", "
                        + "not \(DisplayedText.field(text))"))
            }
            allow.append(allowance)
        }
        return .success(allow)
    }

    /// `--surface` values. Nil when none were passed, so the default applies.
    static func surfaces(_ names: [String]) -> Result<Set<GatewaySurface>?, CommandFailure> {
        guard names.isEmpty == false else { return .success(nil) }
        var surfaces: Set<GatewaySurface> = []
        for name in names {
            guard let surface = GatewaySurface(rawValue: name) else {
                return .failure("--surface must be header, query, or path, not \(DisplayedText.field(name))")
            }
            surfaces.insert(surface)
        }
        return .success(surfaces)
    }

    /// Delivery for `rv secrets set`: explicit flags win; otherwise a new
    /// secret with a well-known name inherits its curated gateway (an
    /// explicit --placeholder-prefix still overrides the curated prefix).
    /// Existing secrets and unknown names resolve to nil, preserving the
    /// established update-value and pass-a-delivery behaviors.
    static func definitionForSet(
        name: String, isNew: Bool, gateway: String?, baseURLEnv: String?,
        placeholderPrefix: String, environment: Bool, surfaces: Set<GatewaySurface>? = nil,
        allow: [GatewayAllowance] = []
    ) -> (definition: Definition?, note: String?) {
        let surfaces = surfaces ?? GatewaySurface.defaults
        if let gateway, let baseURLEnv {
            return (
                .gateway(
                    upstream: gateway, baseURLEnv: baseURLEnv, placeholderPrefix: placeholderPrefix,
                    surfaces: surfaces, allow: allow),
                nil)
        }
        if environment {
            return (.environment, nil)
        }
        guard isNew, let known = KnownSecretDefaults.gateway(for: name) else { return (nil, nil) }
        let prefix = placeholderPrefix.isEmpty ? known.placeholderPrefix : placeholderPrefix
        let definition = Definition.gateway(
            upstream: known.upstream, baseURLEnv: known.baseURLEnv, placeholderPrefix: prefix, surfaces: surfaces,
            allow: allow)
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

    static func list(
        _ configuration: SecretsConfiguration, profiles: [RuntimeResourceProfile], now: Date = Date()
    ) -> ListReport {
        let rows = configuration.secrets.map { secret -> ListRow in
            var upstream: String?
            var baseURLEnv: String?
            let scope = gatewayScope(secret.delivery)
            switch secret.delivery {
            case .gateway(let binding):
                upstream = binding.upstream.absoluteString
                baseURLEnv = binding.baseURLEnv
            case .awsSigV4(let binding):
                upstream = binding.upstream.absoluteString
                baseURLEnv = binding.endpointEnv
            case .environment:
                break
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
                weaker: secret.delivery == .environment,
                surfaces: scope?.surfaces,
                allow: scope?.allow,
                expires: secret.expires.map(SecretExpiry.text),
                refresh: secret.refresh?.text
            )
        }
        var warnings = configuration.secrets.compactMap { expiryWarning($0, now: now) }
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
            if let surfaces = row.surfaces, let allow = row.allow {
                line += "  surfaces: \(surfaces.joined(separator: ","))  allow: \(allowText(allow))"
            }
            if let expires = row.expires { line += "  expires: \(expires)" }
            if let refresh = row.refresh { line += "  refresh: \(refresh)" }
            if row.weaker { line += "  [weaker]" }
            return line
        }
        lines += report.warnings.map { "warning: \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Surfaces and allow rules of a gateway binding; nil for environment delivery.
    /// An AWS placeholder is only ever the key id in the `Authorization` header.
    static func gatewayScope(_ delivery: SecretDelivery) -> (surfaces: [String], allow: [String])? {
        switch delivery {
        case .gateway(let binding):
            (GatewaySurface.ordered(binding.surfaces).map(\.rawValue), binding.allow.map(\.text))
        case .awsSigV4(let binding): ([GatewaySurface.header.rawValue], binding.allow.map(\.text))
        case .environment: nil
        }
    }

    static func allowText(_ allow: [String]) -> String {
        allow.isEmpty ? "any method and path" : allow.joined(separator: "; ")
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
            case .success(let value) where secret.credentialParts(value) == nil:
                return CheckRow(
                    name: secret.name, source: secret.source.locator, ok: false, fingerprint: nil,
                    error: secret.unusableCredentials)
            case .success(let value):
                // The gateway audits the access token itself, not the JSON an oauth source resolves to.
                var shown = value
                if case .oauth = secret.source, let token = secret.credentialParts(value)?.first { shown = token }
                return CheckRow(
                    name: secret.name, source: secret.source.locator, ok: true,
                    fingerprint: fingerprinter?.fingerprint(of: shown), error: nil)
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
    ///
    /// `expires` and `refresh` follow `expiry(_:)` and `refresh(_:)`: nil
    /// keeps what is on file, `.some(nil)` clears it. Unlike delivery, they
    /// may change on an existing secret, since a rotated value often
    /// carries a new expiry.
    static func set(
        name: String, value: Data, definition: Definition?, agents: [String], description: String?,
        environment: SecretsEnvironment, expires: Date?? = nil, refresh: SecretRefreshInterval?? = nil,
        now: Date = Date()
    ) -> Result<String, CommandFailure> {
        guard value.isEmpty == false, value.count <= SecretValue.maximumBytes, value.contains(0) == false else {
            return .failure("the value must be 1 byte to 16 KiB with no NUL bytes")
        }
        if case .some(.some(let date)) = expires, date <= now {
            return .failure(CommandFailure("--expires \(SecretExpiry.text(date)) is already past"))
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
                    "\(DisplayedText.field(name)) reads from \(existing.source.locator); rv secrets set only stores values it reads "
                        + "from \(SecretKeychain.service)"))
            }
            guard definition == nil, agents.isEmpty, description == nil else {
                return .failure("\(DisplayedText.field(name)) is already defined; edit secrets.json to change its delivery")
            }
        } else {
            guard let definition else {
                return .failure("\(DisplayedText.field(name)) is new: pass --gateway URL --base-url-env VAR, or --environment")
            }
            let delivery: SecretDelivery
            switch definition {
            case .environment:
                delivery = .environment
            case .gateway(let upstream, let baseURLEnv, let prefix, let surfaces, let allow):
                guard let url = URL(string: upstream) else { return .failure("--gateway must be an https URL") }
                delivery = .gateway(SecretGatewayBinding(
                    upstream: url, baseURLEnv: baseURLEnv, placeholderPrefix: prefix, surfaces: surfaces,
                    allow: allow))
            }
            updated.secrets.append(SecretDefinition(
                name: name, description: description, agents: agents.isEmpty ? nil : agents,
                source: source, delivery: delivery))
        }
        if let index = updated.secrets.firstIndex(where: { $0.name == name }) {
            if let expires { updated.secrets[index].expires = expires }
            if let refresh { updated.secrets[index].refresh = refresh }
        }
        if updated != current {
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
        if updated != current, case .gateway(let binding) = secret.delivery, binding.allow.isEmpty {
            text += "note: \(DisplayedText.field(name)) may be used with any method and path on "
                + "\(binding.upstream.host ?? binding.upstream.absoluteString); narrow it with --allow, e.g. --allow read-only.\n"
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

    /// Lifts the block rv keeps against an `oauth` secret's refresh token. Touches only the
    /// state file under `<config>/secrets-oauth`; no token is read, sent, or shown.
    static func oauthReset(name: String, environment: SecretsEnvironment) -> Result<String, CommandFailure> {
        let current: SecretsConfiguration
        switch configuration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): current = loaded
        }
        guard let secret = current.secret(named: name) else {
            return .failure("\(DisplayedText.field(name)) is not defined in secrets.json")
        }
        guard case .oauth(let oauth) = secret.source else {
            return .failure("\(DisplayedText.field(name)) is not an oauth secret")
        }
        guard let item = oauth.refreshToken else {
            return .success("\(DisplayedText.field(name)) uses the client credentials grant; rv keeps no block for it.\n")
        }
        switch OAuthRefreshBlock.clear(item, configDirectory: environment.configDirectory) {
        case nil:
            return .failure("another rv process is refreshing \(DisplayedText.field(name)); try again")
        case false?:
            return .success("No block is recorded for \(DisplayedText.field(name)).\n")
        case true?:
            return .success(
                "Cleared the block on \(DisplayedText.field(name)); the next request sends the refresh token in "
                    + "keychain item \(DisplayedText.field(item.service)) / \(DisplayedText.field(item.account)) again.\n"
                    + "If the issuer rotates refresh tokens and an earlier refresh may have been spent, store a new "
                    + "refresh token there instead; resending a spent one can make the issuer revoke the grant.\n")
        }
    }

    struct ScanReport: Encodable, Equatable {
        var findings: [SecretLeakFinding]
        var skipped: [String]
        /// Files over the scanner's size cap: reported, not read.
        var tooLarge: [String] = []
    }

    static func scan(
        root: URL, configuration: SecretsConfiguration, environment: SecretsEnvironment
    ) -> Result<ScanReport, CommandFailure> {
        let values: [(name: String, value: SecretValue)]
        let skipped: [String]
        switch scannableValues(configuration, environment: environment, skippedPrefix: "") {
        case .failure(let failure): return .failure(failure)
        case .success(let resolved): (values, skipped) = resolved
        }
        let report = SecretLeakScanner.scan(root: root, secrets: values)
        return .success(ScanReport(findings: report.findings, skipped: skipped, tooLarge: report.tooLarge))
    }

    /// Values a leak scan looks for. Organization policy applies first: a
    /// source it forbids is never resolved, and an invalid policy fails. Only
    /// the source rule applies: the scan reads on the host and delivers nothing.
    private static func scannableValues(
        _ configuration: SecretsConfiguration, environment: SecretsEnvironment, skippedPrefix: String
    ) -> Result<(values: [(name: String, value: SecretValue)], skipped: [String]), CommandFailure> {
        if let reason = environment.managed.invalidReason {
            return .failure(CommandFailure("organization policy is invalid: \(reason)"))
        }
        var values: [(name: String, value: SecretValue)] = []
        var skipped: [String] = []
        for secret in configuration.secrets {
            if let reason = SecretOrganizationRules.sourceViolation(secret, policy: environment.managed.policy) {
                skipped.append("\(skippedPrefix)\(secret.name): organization policy: \(reason)")
                continue
            }
            // Scan for the long-lived credentials; resolving would mint, and rotate, a token.
            if case .oauth(let oauth) = secret.source {
                for item in [oauth.refreshToken, oauth.clientSecret].compactMap({ $0 }) {
                    switch environment.resolver.resolve(.keychain(service: item.service, account: item.account)) {
                    case .success(let value): values.append((secret.name, value))
                    case .failure(let error): skipped.append("\(skippedPrefix)\(secret.name): \(error.message)")
                    }
                }
                continue
            }
            switch environment.resolver.resolve(secret.source) {
            case .success(let value):
                guard let parts = secret.credentialParts(value) else {
                    skipped.append("\(skippedPrefix)\(secret.name): \(secret.unusableCredentials)")
                    continue
                }
                values += parts.map { (secret.name, $0) }
            case .failure(let error): skipped.append("\(skippedPrefix)\(secret.name): \(error.message)")
            }
        }
        return .success((values, skipped))
    }

    /// Human refusal when `rv secrets scan` is pointed at a file, not a directory.
    static func scanNotADirectory(_ path: String) -> String {
        "\(DisplayedText.field(path)) is not a directory"
    }

    static func scanText(_ report: ScanReport) -> String {
        var lines = report.findings.map { "\(DisplayedText.field($0.path)):\($0.line)  \($0.secret)" }
        if report.findings.isEmpty { lines.append("No secrets found.") }
        lines += report.tooLarge.map(notScanned)
        lines += report.skipped.map { "could not check \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A file the scanner did not read. A warning, not a finding.
    static func notScanned(_ path: String) -> String {
        "not scanned (over \(SecretLeakScanner.maximumFileBytes / 1_048_576) MiB): \(DisplayedText.field(path))"
    }

    struct DescribeRow: Encodable, Equatable {
        var name: String
        var description: String?
        var type: String?
        var delivery: String
        var source: String
        var surfaces: [String]? = nil
        var allow: [String]? = nil
        var expires: String? = nil
        var refresh: String? = nil
    }

    struct DescribeReport: Encodable, Equatable {
        var secrets: [DescribeRow]
        var warnings: [String] = []
    }

    /// Names, descriptions, types, delivery, and gateway scope. No values and no provider locators.
    static func describe(_ configuration: SecretsConfiguration, now: Date = Date()) -> DescribeReport {
        DescribeReport(
            secrets: configuration.secrets.map { secret in
                let scope = gatewayScope(secret.delivery)
                return DescribeRow(
                    name: secret.name, description: secret.description, type: secret.type,
                    delivery: secret.delivery.kind,
                    source: secret.source.kind, surfaces: scope?.surfaces, allow: scope?.allow,
                    expires: secret.expires.map(SecretExpiry.text), refresh: secret.refresh?.text)
            },
            warnings: configuration.secrets.compactMap { expiryWarning($0, now: now) })
    }

    static func describeText(_ report: DescribeReport) -> String {
        guard report.secrets.isEmpty == false else { return "No secrets configured.\n" }
        let rows = report.secrets.map { row in
            var lines = ["\(row.name)  \(row.source)  \(row.delivery)"]
            if let surfaces = row.surfaces, let allow = row.allow {
                lines.append("  surfaces: \(surfaces.joined(separator: ","))")
                lines.append("  allow: \(allowText(allow))")
            }
            if let expires = row.expires { lines.append("  expires: \(expires)") }
            if let refresh = row.refresh { lines.append("  refresh: \(refresh)") }
            if let type = row.type { lines.append("  type: \(type)") }
            if let description = row.description { lines.append("  \(description)") }
            return lines.joined(separator: "\n")
        }
        return (rows + report.warnings.map { "warning: \($0)" }).joined(separator: "\n") + "\n"
    }

    /// A varlock import read and checked, before anything is written.
    struct VarlockImport {
        /// Notes, skips, and one `import` line per fresh secret.
        var lines: [String]
        /// Every secret the schema maps that is defined or about to be; a profile wires all of them.
        var names: [String]
        var fresh: [SecretDefinition]
        var current: SecretsConfiguration
    }

    static func planVarlockImport(path: URL, environment: SecretsEnvironment) -> Result<VarlockImport, CommandFailure> {
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
        var lines = imported.notes
        // secrets.json refuses two secrets setting one variable, so check the merged set.
        var exported = Set(current.secrets.flatMap(\.exportedVariables))
        var fresh: [SecretDefinition] = []
        var names: [String] = []
        for secret in imported.secrets {
            if current.secret(named: secret.name) != nil {
                lines.append("skip \(secret.name): secrets.json already defines it")
                names.append(secret.name)
                continue
            }
            if let taken = secret.exportedVariables.first(where: exported.contains) {
                lines.append("skip \(secret.name): secrets.json or another imported secret already sets $\(taken)")
                continue
            }
            exported.formUnion(secret.exportedVariables)
            lines.append(importLine(secret))
            fresh.append(secret)
            names.append(secret.name)
        }
        return .success(VarlockImport(lines: lines, names: names, fresh: fresh, current: current))
    }

    /// Names where the value comes from and where it goes, never the value.
    static func importLine(_ secret: SecretDefinition) -> String {
        "import \(secret.name): provider \(secret.source.kind), delivery \(secret.delivery.summary)"
            + (secret.type.map { ", type \($0)" } ?? "")
    }

    /// Writes the fresh secrets of a planned import, after org policy allows each.
    static func commitVarlockImport(
        _ pending: VarlockImport, environment: SecretsEnvironment
    ) -> Result<String, CommandFailure> {
        guard pending.fresh.isEmpty == false else {
            return .success((pending.lines + ["nothing to import"]).joined(separator: "\n") + "\n")
        }
        if let reason = environment.managed.invalidReason {
            return .failure("organization policy is invalid: \(reason); nothing imported")
        }
        for secret in pending.fresh {
            if let reason = SecretOrganizationRules.violation(secret, policy: environment.managed.policy) {
                return .failure("organization policy: \(reason); nothing imported")
            }
        }
        var updated = pending.current
        updated.secrets += pending.fresh
        switch updated.write(configDirectory: environment.configDirectory) {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success:
            let count = pending.fresh.count
            let lines = pending.lines + ["wrote secrets.json (\(count) \(count == 1 ? "secret" : "secrets"))"]
            return .success(lines.joined(separator: "\n") + "\n")
        }
    }

    /// `rv secrets import --varlock`. With `profile`, every schema name is
    /// also wired into that existing profile, as `rv init --varlock` does.
    static func importVarlock(
        path: URL, dryRun: Bool, profile: String? = nil, environment: SecretsEnvironment
    ) -> Result<String, CommandFailure> {
        if let profile, dryRun == false,
            SecretsRun.profiles(environment).contains(where: { $0.id == profile }) == false
        {
            return .failure("profile \(DisplayedText.field(profile)) does not exist; run `rv init` to create it")
        }
        let pending: VarlockImport
        switch planVarlockImport(path: path, environment: environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let planned): pending = planned
        }
        if dryRun {
            let tail = pending.fresh.isEmpty ? "nothing to import" : "dry run: nothing written"
            return .success((pending.lines + [tail]).joined(separator: "\n") + "\n")
        }
        var text: String
        switch commitVarlockImport(pending, environment: environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let written): text = written
        }
        guard let profile, pending.names.isEmpty == false else { return .success(text) }
        var wired: [String] = []
        for name in pending.names {
            switch InitRun.attachSecret(name, profileID: profile, configDirectory: environment.configDirectory) {
            case .failure(let failure):
                return .success(text + "warning: imported but not wired into profile \(DisplayedText.field(profile)): \(failure.message)\n")
            case .success(true): wired.append(name)
            case .success(false): break
            }
        }
        if wired.isEmpty == false {
            text += "wired \(wired.joined(separator: ", ")) into profile \(DisplayedText.field(profile))\n"
        }
        return .success(text)
    }

    static func hookRun(workTree: URL, environment: SecretsEnvironment) -> Result<(text: String, failed: Bool), CommandFailure> {
        let configuration: SecretsConfiguration
        switch self.configuration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): configuration = loaded
        }
        let values: [(name: String, value: SecretValue)]
        let skipped: [String]
        switch scannableValues(configuration, environment: environment, skippedPrefix: "could not check ") {
        case .failure(let failure): return .failure(failure)
        case .success(let resolved): (values, skipped) = resolved
        }
        let report: SecretLeakReport
        switch SecretGitHook.scan(workTree: workTree, secrets: values) {
        case .failure(let reason): return .failure(CommandFailure(reason.message))
        case .success(let found): report = found
        }
        let findings = report.findings
        var lines = findings.map { "\(DisplayedText.field($0.path)):\($0.line):\($0.secret)" }
        if findings.isEmpty {
            lines.append("No secrets in staged files.")
        } else {
            lines.append(
                "commit blocked. A false positive: add an `rv-secrets:allow` comment on the line, or "
                    + "path:rule:line to \(SecretLeakIgnore.fileName). Skip the scan: git config \(SecretGitHook.killSwitch) false")
        }
        lines += report.tooLarge.map(notScanned)
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
        abstract: "Manage secrets agents use through placeholders.",
        subcommands: [
            SecretsList.self, SecretsCheck.self, SecretsSet.self, SecretsRemove.self, SecretsOAuthReset.self,
            SecretsScan.self,
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
            Setting a new value reaches running sessions that use the gateway on their next
            request. Environment-delivered values only change for new sessions.
              rv secrets set GITHUB_TOKEN --expires 2027-01-31
            """
    )

    @Argument(help: "Environment variable name the agent sees.") var name: String
    @Option(help: "https upstream the gateway may send this secret to.") var gateway: String?
    @Option(name: .customLong("base-url-env"), help: "Variable that receives the gateway base URL.")
    var baseURLEnv: String?
    @Option(name: .customLong("placeholder-prefix"), help: "Prefix kept on the placeholder (for SDK format checks).")
    var placeholderPrefix: String = ""
    @Option(
        name: .customLong("surface"),
        help: "Where the placeholder may be swapped: header, query, or path (repeatable; default header).")
    var surfaces: [String] = []
    @Option(
        name: .customLong("allow"),
        help: "Allowed method and path: a preset (read-only, github-clone, github-read) or \"GET,HEAD /repos/**\" (repeatable; default any).")
    var allow: [String] = []
    @Flag(help: "Put the real value in the cage environment instead (weaker).") var environment = false
    @Option(name: .customLong("agent"), help: "Only stage for this agent tag (repeatable).") var agents: [String] = []
    @Option(help: "Short description.") var description: String?
    @Option(name: .customLong("resource-profile"), help: "Wire the secret into this runtime profile (see `rv init`).")
    var profile: String?
    @Option(help: "When the value stops being delivered: 2026-12-31 or 2026-12-31T18:00:00Z, or none to clear.")
    var expires: String?
    @Option(help: "Gateway only: re-read the value this often in running sessions, e.g. 15m (min 1m), or none.")
    var refresh: String?

    func validate() throws {
        if environment, gateway != nil { throw ValidationError("pass either --gateway or --environment, not both") }
        if gateway != nil, baseURLEnv == nil { throw ValidationError("--gateway needs --base-url-env") }
        if gateway == nil, baseURLEnv != nil { throw ValidationError("--base-url-env needs --gateway") }
        if environment, surfaces.isEmpty == false { throw ValidationError("--surface applies to gateway delivery") }
        if case .failure(let failure) = SecretsRun.surfaces(surfaces) { throw ValidationError(failure.message) }
        if environment, allow.isEmpty == false { throw ValidationError("--allow applies to gateway delivery") }
        if case .failure(let failure) = SecretsRun.allowances(allow) { throw ValidationError(failure.message) }
        if case .failure(let failure) = SecretsRun.expiry(expires) { throw ValidationError(failure.message) }
        if case .failure(let failure) = SecretsRun.refresh(refresh) { throw ValidationError(failure.message) }
        if environment, refresh != nil, refresh != "none" {
            throw ValidationError("--refresh applies to gateway delivery; an environment value cannot change after launch")
        }
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
            placeholderPrefix: placeholderPrefix, environment: self.environment,
            surfaces: try? SecretsRun.surfaces(surfaces).get(),
            allow: (try? SecretsRun.allowances(allow).get()) ?? [])
        let definition = resolved.definition
        if surfaces.isEmpty == false || allow.isEmpty == false, definition == nil, isNew == false {
            try ctx.fail(
                "rv secrets set: \(DisplayedText.field(name)) is already defined; edit secrets.json to change its surfaces or allow rules\n")
        }
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
            environment: environment, expires: try? SecretsRun.expiry(expires).get(),
            refresh: try? SecretsRun.refresh(refresh).get())
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

struct SecretsOAuthReset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "oauth-reset",
        abstract: "Lift the block on an oauth secret's refresh token so rv sends it again. Touches no token.")

    @Argument var name: String

    func run() throws {
        let ctx = CommandContext.current(command: "secrets oauth-reset", json: false, robot: false, plain: true, noColor: true)
        switch SecretsRun.oauthReset(name: name, environment: .live(home: try ctx.requireHome())) {
        case .failure(let failure): try ctx.fail("rv secrets oauth-reset: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}

struct SecretsScan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Find secret values rv can resolve and known token patterns in a tree (exits 1 on findings).")

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
        let report: SecretsRun.ScanReport
        switch SecretsRun.scan(root: root, configuration: configuration, environment: environment) {
        case .failure(let failure): try ctx.fail("rv secrets scan: \(failure.message)\n")
        case .success(let scanned): report = scanned
        }
        let text = ctx.explicitRobot ? SecretsRun.robotJSON(report) : SecretsRun.scanText(report)
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
    @Option(name: .customLong("resource-profile"), help: "Also wire every schema secret into this existing profile.")
    var profile: String?

    func run() throws {
        let ctx = CommandContext.current(command: "secrets import", json: false, robot: false, plain: true, noColor: true)
        let environment = SecretsEnvironment.live(home: try ctx.requireHome())
        let path = URL(fileURLWithPath: varlock).standardizedFileURL
        switch SecretsRun.importVarlock(path: path, dryRun: dryRun, profile: profile, environment: environment) {
        case .failure(let failure): try ctx.fail("rv secrets import: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}

struct SecretsHook: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Git pre-commit hook that scans staged content for secret values and token patterns.",
        subcommands: [SecretsHookInstall.self, SecretsHookUninstall.self, SecretsHookRun.self])
}

struct SecretsHookInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Add rv's block to this repository's pre-commit hook. Safe to run again.")

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
        commandName: "uninstall", abstract: "Remove rv's block from the pre-commit hook, leaving the rest.")

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
