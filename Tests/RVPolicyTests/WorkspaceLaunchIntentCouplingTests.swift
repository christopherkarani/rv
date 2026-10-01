import Foundation
import RVDomain
import Testing
@testable import RVPolicy

/// Agreement between launch selection and `WorkspaceLaunchIntent`.
///
/// Selection resolves trusted operator state into a launch snapshot; the
/// intent freezes the authorizable operation. Where the two overlap, their
/// accept/reject behavior must agree exactly; where they intentionally
/// diverge (pinned requirements bind without verifying), these tests pin
/// the divergence so nobody "fixes" it by accident.
@Suite("Workspace launch intent coupling")
struct WorkspaceLaunchIntentCouplingTests {
    private let project = "/tmp/identity-project"

    private func definition(
        id: String = "trusted-agent",
        target: String = "/bin/cat",
        requirement: ExecutableRequirement = ExecutableRequirement(allowsUnsigned: true),
        credentialBindings: [String] = []
    ) -> AgentDefinition {
        AgentDefinition(
            id: AgentDefinitionID(rawValue: id),
            displayName: "Trusted agent",
            blurb: "",
            executableRequirement: requirement,
            hookHost: nil,
            agentTag: nil,
            resourceProfile: RuntimeResourceProfile(
                id: "identity",
                projects: [project],
                executableLinks: [.init(name: id, target: target)]
            ),
            credentialBindings: credentialBindings,
            requiredAssurance: .launchObserved,
            authorityCeiling: .none
        )
    }

    private func set(_ definition: AgentDefinition) -> AgentDefinitionSet {
        AgentDefinitionSet(resolved: [
            ResolvedAgentDefinition(
                definition: definition,
                revision: AgentDefinitionRevision.resolve(definition)
            ),
        ])
    }

    @Test func reservedSnapshotIDMatchesIntentRejection() {
        #expect(AgentDefinitionStore.reservedSnapshotID == "adhoc")
        let snapshot = definition(id: AgentDefinitionStore.reservedSnapshotID)
        #expect(
            WorkspaceLaunchIntent.makeNamed(
                definition: snapshot,
                revision: AgentDefinitionRevision.resolve(snapshot),
                resolvedExecutable: "/bin/cat",
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: project,
                arguments: [],
                io: .discard
            ) == .failure(.reservedDefinitionID)
        )
    }

    @Test func namedSelectionOutputBuildsIdenticalIntent() throws {
        let selected = try AgentLaunchSelection.resolveNamed(
            id: AgentDefinitionID(rawValue: "trusted-agent"),
            definitions: set(definition()),
            project: project
        ).get()
        let intent = try WorkspaceLaunchIntent.makeNamed(
            definition: selected.resolved.definition,
            revision: selected.resolved.revision,
            resolvedExecutable: selected.executable,
            workspaceSessionID: WorkspaceSessionID(),
            workingDirectory: project,
            arguments: ["hello"],
            io: .discard
        ).get()
        guard case .named(let named) = intent.target else {
            Issue.record("expected named target")
            return
        }
        #expect(named.definitionID.rawValue == "trusted-agent")
        #expect(named.definitionRevision == selected.resolved.revision)
        #expect(named.resolvedExecutable == selected.executable)
    }

    @Test func customSelectionOutputBuildsIdenticalIntent() throws {
        let digest = String(repeating: "ab", count: 32)
        let selected = try AgentLaunchSelection.resolveCustom(
            executable: "/tmp/agent",
            expectedContentDigestSHA256: digest
        ).get()
        let intent = try WorkspaceLaunchIntent.makeCustom(
            executable: selected.executable,
            expectedContentDigestSHA256: digest,
            workspaceSessionID: WorkspaceSessionID(),
            workingDirectory: project,
            arguments: [],
            io: .discard
        ).get()
        guard case .custom(let custom) = intent.target else {
            Issue.record("expected custom target")
            return
        }
        #expect(custom.executable == selected.executable)
        #expect(custom.expectedContentDigestSHA256 == digest)
        // The ad-hoc snapshot revision is a pure function of the digest over
        // a fixed template, so binding the digest binds the revision: the
        // same digest yields the same snapshot revision for any executable.
        let other = try AgentLaunchSelection.resolveCustom(
            executable: "/tmp/other",
            expectedContentDigestSHA256: digest
        ).get()
        #expect(other.resolved.revision == selected.resolved.revision)
        #expect(other.resolved.definition.id.rawValue == AgentDefinitionStore.reservedSnapshotID)
    }

    @Test func customDigestAcceptanceAgrees() {
        let valid = [String(repeating: "0", count: 64), String(repeating: "f", count: 64)]
        let invalid = ["", "abc", String(repeating: "AB", count: 32),
            String(repeating: "a", count: 63), String(repeating: "g", count: 64)]
        for digest in valid {
            #expect(AdHocAgentSnapshot.make(expectedContentDigestSHA256: digest) != nil)
            #expect(
                WorkspaceLaunchIntent.makeCustom(
                    executable: "/tmp/agent",
                    expectedContentDigestSHA256: digest,
                    workspaceSessionID: WorkspaceSessionID(),
                    workingDirectory: project,
                    arguments: [],
                    io: .discard
                ).isSuccess
            )
        }
        for digest in invalid {
            #expect(AdHocAgentSnapshot.make(expectedContentDigestSHA256: digest) == nil)
            #expect(
                WorkspaceLaunchIntent.makeCustom(
                    executable: "/tmp/agent",
                    expectedContentDigestSHA256: digest,
                    workspaceSessionID: WorkspaceSessionID(),
                    workingDirectory: project,
                    arguments: [],
                    io: .discard
                ) == .failure(.invalidExpectedDigest)
            )
        }
    }

    @Test func customExecutableAcceptanceAgrees() {
        let digest = String(repeating: "ab", count: 32)
        let boundary = "/bin/" + String(repeating: "a", count: 1019)
        let valid = ["/bin/cat", "/a", "/tmp/a\tb", boundary]
        let invalid = ["", "cat", "/", "/tmp/\0cat", "/tmp/../cat", "/tmp//cat", "/tmp/cat\n",
            "/a/", boundary + "x"]
        for path in valid {
            #expect(
                AgentLaunchSelection.resolveCustom(
                    executable: path, expectedContentDigestSHA256: digest
                ).isSuccess,
                "selection accepts \(path.debugDescription)"
            )
            #expect(
                WorkspaceLaunchIntent.makeCustom(
                    executable: path,
                    expectedContentDigestSHA256: digest,
                    workspaceSessionID: WorkspaceSessionID(),
                    workingDirectory: project,
                    arguments: [],
                    io: .discard
                ).isSuccess,
                "intent accepts \(path.debugDescription)"
            )
        }
        for path in invalid {
            #expect(
                AgentLaunchSelection.resolveCustom(
                    executable: path, expectedContentDigestSHA256: digest
                ) == .failure(.invalidExecutable),
                "selection rejects \(path.debugDescription)"
            )
            #expect(
                WorkspaceLaunchIntent.makeCustom(
                    executable: path,
                    expectedContentDigestSHA256: digest,
                    workspaceSessionID: WorkspaceSessionID(),
                    workingDirectory: project,
                    arguments: [],
                    io: .discard
                ) == .failure(.invalidExecutable),
                "intent rejects \(path.debugDescription)"
            )
        }
    }

    @Test func pinnedRequirementsBindWithoutVerifying() throws {
        // Intentional divergence: the intent binds what the operator asks
        // for (including pinned requirements, which are fully specified),
        // while selection still defers what the launch path cannot verify.
        let pinned = definition(requirement: ExecutableRequirement(
            expectedContentDigestSHA256: String(repeating: "ab", count: 32)
        ))
        #expect(AgentLaunchSelection.resolveNamed(
            id: AgentDefinitionID(rawValue: "trusted-agent"),
            definitions: set(pinned),
            project: project
        ) == .failure(.unsupportedExecutableRequirement))
        #expect(
            try WorkspaceLaunchIntent.makeNamed(
                definition: pinned,
                revision: AgentDefinitionRevision.resolve(pinned),
                resolvedExecutable: "/bin/cat",
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: project,
                arguments: [],
                io: .discard
            ).get().auditSummary.kind == .named
        )
    }

    @Test func credentialBearingShapesAreRejectedByBoth() throws {
        let bound = definition(credentialBindings: ["token"])
        #expect(AgentLaunchSelection.resolveNamed(
            id: AgentDefinitionID(rawValue: "trusted-agent"),
            definitions: set(bound),
            project: project
        ) == .failure(.credentialIntegrationDeferred))
        #expect(
            WorkspaceLaunchIntent.makeNamed(
                definition: bound,
                revision: AgentDefinitionRevision.resolve(bound),
                resolvedExecutable: "/bin/cat",
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: project,
                arguments: [],
                io: .discard
            ) == .failure(.credentialStagingNotSupported)
        )
    }
}

private extension Result {
    var isSuccess: Bool {
        switch self {
        case .success:
            true
        case .failure:
            false
        }
    }
}
