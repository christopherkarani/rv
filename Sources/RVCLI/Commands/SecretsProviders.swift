import ArgumentParser
import Foundation
import RVDomain
import RVIsolation

/// `rv secrets providers` and the `--provider` expansion of `rv secrets set`.
extension SecretsRun {
    struct ProviderEndpointRow: Encodable, Equatable {
        var name: String
        var upstream: String
        var surfaces: [String]
        /// Presets and rules; empty allows any method and path.
        var allow: [String]
    }

    struct ProviderCredentialRow: Encodable, Equatable {
        var variable: String
        var baseURLEnv: String
        var placeholderPrefix: String
        var endpoint: String
    }

    struct ProviderRow: Encodable, Equatable {
        var id: String
        var displayName: String
        var description: String
        var endpoints: [ProviderEndpointRow]
        var credentials: [ProviderCredentialRow]
        var binaries: [String]?
        var notes: [String]
    }

    struct ProvidersReport: Encodable, Equatable {
        var providers: [ProviderRow]
    }

    static func providerRow(_ profile: ProviderProfile) -> ProviderRow {
        ProviderRow(
            id: profile.id, displayName: profile.displayName, description: profile.description,
            endpoints: profile.endpoints.map {
                ProviderEndpointRow(
                    name: $0.name, upstream: $0.upstream.absoluteString,
                    surfaces: GatewaySurface.ordered($0.surfaces).map(\.rawValue), allow: $0.allow.map(\.text))
            },
            credentials: profile.credentials.map {
                ProviderCredentialRow(
                    variable: $0.variable, baseURLEnv: $0.baseURLEnv, placeholderPrefix: $0.placeholderPrefix,
                    endpoint: $0.endpoint)
            },
            binaries: profile.binaries, notes: profile.notes)
    }

    /// Every profile, or the one named `id`.
    static func providers(
        _ id: String?, catalog: Result<ProviderCatalog, ProviderCatalogError> = ProviderCatalog.shipped
    ) -> Result<ProvidersReport, CommandFailure> {
        let loaded: ProviderCatalog
        switch catalog {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success(let value): loaded = value
        }
        guard let id else { return .success(ProvidersReport(providers: loaded.profiles.map(providerRow))) }
        guard let profile = loaded.profile(id: id) else {
            return .failure(CommandFailure(ProviderExpansionError.unknownProvider(id).message))
        }
        return .success(ProvidersReport(providers: [providerRow(profile)]))
    }

    static func providersListText(_ report: ProvidersReport) -> String {
        let width = report.providers.map(\.id.count).max() ?? 0
        let lines = report.providers.map { row in
            let variables = row.credentials.map(\.variable).joined(separator: ",")
            return row.id.padding(toLength: width, withPad: " ", startingAt: 0)
                + "  \(row.description)  variables: \(variables.isEmpty ? "-" : variables)"
        }
        return (lines + ["Details: rv secrets providers <id>"]).joined(separator: "\n") + "\n"
    }

    static func providerShowText(_ row: ProviderRow) -> String {
        var lines = ["\(row.id)  \(row.displayName)", "  \(row.description)"]
        for endpoint in row.endpoints {
            lines.append(
                "  endpoint \(endpoint.name): \(endpoint.upstream)  surfaces: \(endpoint.surfaces.joined(separator: ","))"
                    + "  allow: \(allowText(endpoint.allow))")
        }
        for credential in row.credentials {
            let prefix = credential.placeholderPrefix.isEmpty ? "" : "  placeholder prefix: \(credential.placeholderPrefix)"
            lines.append("  \(credential.variable) -> \(credential.endpoint) via $\(credential.baseURLEnv)\(prefix)")
        }
        if let binaries = row.binaries { lines.append("  binaries: \(binaries.joined(separator: ", "))") }
        lines += row.notes.map { "  note: \($0)" }
        if let first = row.credentials.first {
            lines.append("  use: rv secrets set \(first.variable) --provider \(row.id)")
        } else {
            lines.append("  use: rv secrets set NAME --provider \(row.id) --base-url-env VAR")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The gateway delivery `--provider` expands to, and the line that says
    /// so. The profile is the ceiling: `--surface` and `--allow` may only
    /// narrow it. On an existing secret, `set` accepts it only when it is
    /// the definition already on file.
    static func definitionForProvider(
        _ selector: String, name: String, baseURLEnv: String?, placeholderPrefix: String,
        surfaces: Set<GatewaySurface>?, allow: [GatewayAllowance],
        catalog: Result<ProviderCatalog, ProviderCatalogError> = ProviderCatalog.shipped
    ) -> Result<(definition: Definition, note: String), CommandFailure> {
        let loaded: ProviderCatalog
        switch catalog {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success(let value): loaded = value
        }
        let expansion: ProviderExpansion
        switch loaded.expand(
            selector, secret: name, baseURLEnv: baseURLEnv, placeholderPrefix: placeholderPrefix, surfaces: surfaces,
            allow: allow)
        {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success(let value): expansion = value
        }
        let definition = Definition.gateway(
            upstream: expansion.upstream.absoluteString, baseURLEnv: expansion.baseURLEnv,
            placeholderPrefix: expansion.placeholderPrefix, surfaces: expansion.surfaces, allow: expansion.allow,
            binaries: expansion.binaries)
        let note = "Using provider \(expansion.profile):\(expansion.endpoint) for \(DisplayedText.field(name)): gateway "
            + "\(expansion.upstream.absoluteString) via $\(expansion.baseURLEnv), allow: "
            + "\(allowText(expansion.allow.map(\.text))).\n"
        return .success((definition, note))
    }
}

struct SecretsProviders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "providers",
        abstract: "List the provider profiles `rv secrets set --provider` expands, or show one.")

    @Argument(help: "Profile id, e.g. github. Default: list all.") var id: String?
    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "secrets providers", format: format)
        let report: SecretsRun.ProvidersReport
        switch SecretsRun.providers(id) {
        case .failure(let failure): try ctx.fail("rv secrets providers: \(failure.message)\n")
        case .success(let value): report = value
        }
        if ctx.explicitRobot {
            ctx.writeStdout(try RobotJSON.encode(report, options: .pretty))
        } else if id != nil, let row = report.providers.first {
            ctx.writeStdout(SecretsRun.providerShowText(row))
        } else {
            ctx.writeStdout(SecretsRun.providersListText(report))
        }
    }
}
