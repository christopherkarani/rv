import RVDomain

public enum AgentLaunchSelectionError: Error, Sendable, Equatable {
    case unknownDefinition
    case invalidDefinition
    case projectNotEligible
    case executableUnavailable
    case invalidExecutable
    case unsupportedExecutableRequirement
    case credentialIntegrationDeferred
    case invalidCustomDigest
}

/// One immutable operator selection for an identity-aware runtime launch.
/// Selecting a trusted definition does not verify the executing image.
public struct ResolvedAgentLaunch: Sendable, Equatable {
    public let resolved: ResolvedAgentDefinition
    public let executable: String
    public let resourceProfile: RuntimeResourceProfile?

    init(
        resolved: ResolvedAgentDefinition, executable: String,
        resourceProfile: RuntimeResourceProfile?
    ) {
        self.resolved = resolved
        self.executable = executable
        self.resourceProfile = resourceProfile
    }
}

/// Pure selection from a host-loaded operator definition snapshot.
/// The request supplies an ID, never an executable override for a named agent.
public enum AgentLaunchSelection {
    public static func resolveNamed(
        id: AgentDefinitionID, definitions: AgentDefinitionSet, project: String
    ) -> Result<ResolvedAgentLaunch, AgentLaunchSelectionError> {
        guard let resolved = definitions.resolved.first(where: { $0.definition.id == id }) else {
            return .failure(.unknownDefinition)
        }
        guard AgentDefinitionID(validating: id.rawValue) != nil,
            id.rawValue != AgentDefinitionStore.reservedSnapshotID,
            resolved.revision == AgentDefinitionRevision.resolve(resolved.definition)
        else { return .failure(.invalidDefinition) }
        let definition = resolved.definition
        let profile = definition.resourceProfile
        guard profile.projects.contains(project) else { return .failure(.projectNotEligible) }
        let requirement = definition.executableRequirement
        // Content/signing verification and credential integration are separate
        // phases. This entry point accepts only explicitly weak unsigned launches.
        guard requirement.allowsUnsigned,
            requirement.expectedContentDigestSHA256 == nil,
            requirement.requiredTeamID == nil,
            requirement.requiredCodeRequirement == nil
        else { return .failure(.unsupportedExecutableRequirement) }
        guard definition.credentialBindings.isEmpty,
            profile.credentials.isEmpty, profile.keychain.isEmpty
        else { return .failure(.credentialIntegrationDeferred) }
        let links = profile.executableLinks.filter { $0.name == id.rawValue }
        guard links.count == 1 else { return .failure(.executableUnavailable) }
        let executable = links[0].target
        guard validExecutable(executable) else { return .failure(.invalidExecutable) }
        return .success(ResolvedAgentLaunch(
            resolved: resolved, executable: executable, resourceProfile: profile
        ))
    }

    public static func resolveCustom(
        executable: String, expectedContentDigestSHA256: String
    ) -> Result<ResolvedAgentLaunch, AgentLaunchSelectionError> {
        guard validExecutable(executable) else { return .failure(.invalidExecutable) }
        // Snapshot intent: the host measures the bytes against this digest
        // at prepare and again at spawn commit (M4); selection alone never
        // executes.
        guard let snapshot = AdHocAgentSnapshot.make(
            expectedContentDigestSHA256: expectedContentDigestSHA256
        ) else { return .failure(.invalidCustomDigest) }
        return .success(ResolvedAgentLaunch(
            resolved: ResolvedAgentDefinition(definition: snapshot.definition, revision: snapshot.revision),
            executable: executable, resourceProfile: nil
        ))
    }

    private static func validExecutable(_ value: String) -> Bool {
        value.hasPrefix("/") && value != "/" && value.utf8.count <= 1_024
            && !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
            && value.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
