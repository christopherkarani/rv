import Foundation
import RVDomain
import Testing
@testable import RVPolicy

@Suite("Agent launch selection")
struct AgentLaunchSelectionTests {
    private let id = AgentDefinitionID(rawValue: "trusted-agent")
    private let project = "/tmp/identity-project"

    @Test func namedLaunchUsesOperatorExecutableAndResolvedRevision() throws {
        let definitions = try loaded()
        let launch = try AgentLaunchSelection.resolveNamed(
            id: id, definitions: definitions, project: project
        ).get()
        #expect(launch.executable == "/bin/cat")
        #expect(launch.resolved == definitions.resolved[0])
        #expect(launch.resolved.revision == AgentDefinitionRevision.resolve(launch.resolved.definition))
        #expect(launch.resourceProfile == launch.resolved.definition.resourceProfile)
        let changed = try loaded(target: "/bin/echo")
        #expect(changed.resolved[0].revision != launch.resolved.revision)
        #expect(launch.executable == "/bin/cat")
    }

    @Test func unknownDefinitionAndBasenameCannotSelectIdentity() throws {
        let definitions = try loaded()
        for unknown in ["missing", "cat", "claude", "adhoc"] {
            #expect(AgentLaunchSelection.resolveNamed(
                id: AgentDefinitionID(rawValue: unknown), definitions: definitions, project: project
            ) == .failure(.unknownDefinition))
        }
    }

    @Test func mismatchedRevisionCannotBecomeLaunchSnapshot() throws {
        let definitions = try loaded()
        let invalid = AgentDefinitionSet(resolved: [ResolvedAgentDefinition(
            definition: definitions.resolved[0].definition,
            revision: AgentDefinitionRevision(digestHex: String(repeating: "0", count: 64))
        )])
        #expect(AgentLaunchSelection.resolveNamed(
            id: id, definitions: invalid, project: project
        ) == .failure(.invalidDefinition))
    }

    @Test func hookMetadataDoesNotSelectExecutableOrIdentity() throws {
        let definitions = try loaded(hook: "claude")
        let launch = try AgentLaunchSelection.resolveNamed(
            id: id, definitions: definitions, project: project
        ).get()
        #expect(launch.resolved.definition.id == id)
        #expect(launch.executable == "/bin/cat")
        #expect(AgentLaunchSelection.resolveNamed(
            id: AgentDefinitionID(rawValue: "claude"), definitions: definitions, project: project
        ) == .failure(.unknownDefinition))
    }

    @Test func customSnapshotCannotInheritNamedGrants() throws {
        let launch = try AgentLaunchSelection.resolveCustom(
            executable: "/tmp/claude", expectedContentDigestSHA256: String(repeating: "ab", count: 32)
        ).get()
        #expect(launch.executable == "/tmp/claude")
        #expect(launch.resourceProfile == nil)
        #expect(launch.resolved.definition.id.rawValue == "adhoc")
        #expect(launch.resolved.definition.credentialBindings.isEmpty)
        #expect(launch.resolved.definition.authorityCeiling == .none)
        #expect(launch.resolved.definition.hookHost == nil)
        #expect(launch.resolved.definition.agentTag == nil)
        #expect(launch.resolved.definition.resourceProfile.projects.isEmpty)
        #expect(launch.resolved.definition.requiredAssurance == .unattested)
        #expect(launch.resolved.revision == AgentDefinitionRevision.resolve(launch.resolved.definition))
    }

    @Test func malformedCustomPathOrDigestRefusesSelection() {
        for path in ["", "cat", "/", "/tmp/\0cat", "/tmp/../cat", "/tmp//cat", "/tmp/cat\n"] {
            #expect(AgentLaunchSelection.resolveCustom(
                executable: path, expectedContentDigestSHA256: String(repeating: "ab", count: 32)
            ) == .failure(.invalidExecutable))
        }
        for digest in ["", "abc", String(repeating: "AB", count: 32)] {
            #expect(AgentLaunchSelection.resolveCustom(
                executable: "/bin/cat", expectedContentDigestSHA256: digest
            ) == .failure(.invalidCustomDigest))
        }
    }

    @Test func profileMustServeExactProjectAndName() throws {
        #expect(AgentLaunchSelection.resolveNamed(
            id: id, definitions: try loaded(), project: project + "-other"
        ) == .failure(.projectNotEligible))
        #expect(AgentLaunchSelection.resolveNamed(
            id: id, definitions: try loaded(linkName: "cat"), project: project
        ) == .failure(.executableUnavailable))
        #expect(AgentLaunchSelection.resolveNamed(
            id: id, definitions: try loaded(duplicateLink: true), project: project
        ) == .failure(.executableUnavailable))
        #expect(AgentLaunchSelection.resolveNamed(
            id: id, definitions: try loaded(target: "cat"), project: project
        ) == .failure(.invalidExecutable))
    }

    @Test func pinnedRequirementsAndCredentialIntegrationAreDeferred() throws {
        let requirements: [[String: Any]] = [
            ["expectedContentDigestSHA256": String(repeating: "ab", count: 32), "allowsUnsigned": true],
            ["requiredTeamID": "ABCDE12345", "allowsUnsigned": true],
            ["requiredCodeRequirement": "identifier trusted-agent", "allowsUnsigned": true],
        ]
        for requirement in requirements {
            #expect(AgentLaunchSelection.resolveNamed(
                id: id, definitions: try loaded(requirement: requirement), project: project
            ) == .failure(.unsupportedExecutableRequirement))
        }
        for kind in 0..<3 {
            #expect(AgentLaunchSelection.resolveNamed(
                id: id, definitions: try loaded(credentialKind: kind), project: project
            ) == .failure(.credentialIntegrationDeferred))
        }
    }

    private func loaded(
        target: String = "/bin/cat", linkName: String = "trusted-agent",
        hook: String? = nil, duplicateLink: Bool = false,
        requirement: [String: Any] = ["allowsUnsigned": true], credentialKind: Int? = nil
    ) throws -> AgentDefinitionSet {
        var profile = RuntimeResourceProfile(
            id: "identity", projects: [project],
            executableLinks: [.init(name: linkName, target: target)]
        )
        if duplicateLink { profile.executableLinks.append(.init(name: linkName, target: "/bin/echo")) }
        if credentialKind == 1 {
            profile.credentials = [.init(source: "/tmp/token", destination: "token")]
        }
        if credentialKind == 2 {
            profile.keychain = [.init(service: "service", account: "account", env: "TOKEN")]
        }
        var definition: [String: Any] = [
            "id": id.rawValue, "displayName": "Trusted agent", "blurb": "",
            "executable": requirement, "resourceProfile": profile.id,
            "credentialBindings": credentialKind == 0 ? ["token"] : [],
            "requiredAssurance": "launchObserved", "authorityCeiling": ["shell.exec"],
        ]
        if let hook { definition["hookHost"] = hook }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "definitions": [definition]])
        return try AgentDefinitionStore.decode(data, resourcePolicy: .init(profiles: [profile])).get()
    }
}
