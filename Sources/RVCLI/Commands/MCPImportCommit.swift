import Foundation
import RVDomain
import RVFileStore
import RVIsolation
import RVMCP
import RVPolicy

extension MCPRun {
    /// The write half of `rv mcp import`, shared with `rv mcp add`: check
    /// mcp.json's integrity and the organization's secret rules, show the
    /// review, ask the device owner once, then store each credential in
    /// the Keychain (by name in secrets.json) and sign mcp.json with the
    /// new servers. Any failure after a write rolls back what it stored.
    /// `routes` are host config rewrites the same confirmation covers.
    static func commitImport(
        _ plan: MCPImportPlan, base: MCPStoredConfiguration, secrets: SecretsConfiguration,
        environment: MCPEnvironment, toolModeForFreshConfig: MCPToolMode?, routes: [String] = [],
        show: @escaping @Sendable (String) -> Void
    ) async -> Result<Void, CommandFailure> {
        let configuration = base.configuration
        let integrity = MCPIntegrity.status(
            of: base.bytes, configDirectory: environment.configDirectory, signing: environment.approvalSigning)
        if let problem = integrity.problem {
            return .failure(CommandFailure("\(problem); nothing imported"))
        }
        if let definition = plan.secrets.first?.definition,
            let reason = SecretOrganizationRules.violation(definition, policy: environment.managed.policy)
        {
            return .failure(CommandFailure("organization policy: \(reason); nothing imported"))
        }

        for secret in plan.secrets where SecretValue(secret.value) == nil {
            return .failure(CommandFailure(
                "\(secret.definition.name) is empty, contains NUL, or is over \(SecretValue.maximumBytes) bytes; nothing imported"))
        }
        let review = importPresenceReview(servers: plan.servers, routes: routes)
        guard reviewShowsEveryLiteral(plan, review.shown) else {
            return .failure(CommandFailure("import review omitted a literal value; nothing imported"))
        }
        show(review.shown)
        let outcome = await environment.presence.confirm(review.reason, .deviceOwner)
        guard case .confirmed = outcome else {
            let refusal = if case .refused(let why) = outcome { why } else { "not confirmed" }
            return .failure(CommandFailure("not imported: \(refusal); nothing imported"))
        }
        var stored: [String] = []
        func rollback() -> Bool {
            stored.allSatisfy { environment.keychain.delete(SecretKeychain.service, $0) }
        }
        func keychainFailure(_ name: String) -> CommandFailure {
            let cleared = rollback()
            let tail = cleared
                ? "nothing imported"
                : "could not remove secrets this import already stored in \(SecretKeychain.storeName)"
            return CommandFailure("could not store \(name) \(SecretKeychainWriter.storeFailureSuffix); \(tail)")
        }
        for secret in plan.secrets {
            guard environment.keychain.store(SecretKeychain.service, secret.definition.name, Data(secret.value.utf8)) else {
                return .failure(keychainFailure(secret.definition.name))
            }
            stored.append(secret.definition.name)
        }
        if plan.secrets.isEmpty == false {
            var updatedSecrets = secrets
            updatedSecrets.secrets += plan.secrets.map(\.definition)
            if case .failure(let error) = updatedSecrets.write(configDirectory: environment.configDirectory) {
                let cleared = rollback()
                let message = cleared ? error.message : "\(error.message); could not remove secrets this import already stored in \(SecretKeychain.storeName)"
                return .failure(CommandFailure(message))
            }
        }
        var updated = configuration
        updated.servers += plan.servers
        // A first import chooses the compact tool listing: clients see only
        // rv_search_tools and rv_call_tool instead of every upstream schema.
        // Existing configs keep whatever mode the operator already chose.
        if let toolModeForFreshConfig, configuration.servers.isEmpty {
            updated.toolMode = toolModeForFreshConfig
        }
        // End any custodian auth window an earlier key use opened (the
        // integrity check) so signing authenticates for itself, after the
        // confirmed review.
        environment.approvalSigning.beginFreshAuth()
        if case .failure(let error) = updated.write(configDirectory: environment.configDirectory, signing: environment.approvalSigning) {
            let restoredSecrets: Bool
            if plan.secrets.isEmpty {
                restoredSecrets = true
            } else if case .success = secrets.write(configDirectory: environment.configDirectory) {
                restoredSecrets = true
            } else {
                restoredSecrets = false
            }
            let cleared = rollback()
            let message = restoredSecrets && cleared
                ? error.message
                : "\(error.message); could not remove secrets this import already stored"
            return .failure(CommandFailure(message))
        }
        guard fileMatches(updated, configDirectory: environment.configDirectory) else {
            return .failure(CommandFailure("mcp.json changed while it was being signed"))
        }
        return .success(())
    }
}
