import Foundation
import RVDomain
import Testing
@testable import RVIsolation

private struct PrincipalAuthorityHarness {
    let root: URL
    let journal: URL
    let registry: AgentInstanceRegistry
    let instance: AgentInstance
    let session: RuntimeSession
    let authority: WorkspacePrincipalAuthority

    init(active: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-principal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        journal = root.appendingPathComponent("instances.jsonl")
        registry = AgentInstanceRegistry(journal: .file(journal))
        let workspace = WorkspaceSessionID()
        let runtime = RuntimeSessionID()
        instance = AgentInstance(
            id: AgentInstanceID(), owner: OwnerPrincipal.current(),
            definitionID: AgentDefinitionID(rawValue: "test"),
            definitionRevision: AgentDefinitionRevision(digestHex: String(repeating: "a", count: 64)),
            workspaceSessionID: workspace, runtimeSessionID: runtime,
            executableEvidence: .none, assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 100), workloadProcess: nil, parent: nil,
            effectiveAuthority: AgentAuthority(scopes: []), delegableAuthority: AgentAuthority(scopes: []),
            mintedAt: Date()
        )
        session = RuntimeSession(
            id: runtime, workspaceSessionID: workspace, host: .opencode,
            workspace: try #require(WorkingDirectory(validating: root.path)),
            backend: .seatbelt, startedAt: Date(), child: nil
        )
        authority = WorkspacePrincipalAuthority(registry: registry, workspace: workspace, host: WorkspaceHostID())
        #expect(registry.announce(instance))
        if active {
            let established = try #require(EstablishedRuntimeSession(
                session: session, instance: instance, establishedAt: Date()
            ))
            #expect(registry.activate(established)?.validity == .active)
        }
    }

    var reference: AgentPrincipalReference {
        AgentPrincipalReference(
            agentInstanceID: instance.id, runtimeSessionID: session.id,
            workspaceSessionID: authority.workspace, workspaceHostID: authority.host,
            workspaceHostGeneration: authority.generation
        )
    }
}

@Suite struct WorkspacePrincipalAuthorityTests {
    @Test func activeLookupAndRevocation() throws {
        let h = try PrincipalAuthorityHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        #expect(h.authority.reference(forRuntime: h.session.id) == h.reference)
        #expect(h.authority.resolve(h.reference)?.validity == .active)
        #expect(h.registry.revoke(h.instance.id, reason: .explicitRevoke) { true } == .revoked)
        #expect(h.authority.resolve(h.reference) == nil)
        #expect(h.authority.reference(forRuntime: h.session.id) == nil)
    }

    @Test func everyReferenceFieldIsRequired() throws {
        let h = try PrincipalAuthorityHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let r = h.reference
        let mismatches = [
            AgentPrincipalReference(agentInstanceID: AgentInstanceID(), runtimeSessionID: r.runtimeSessionID,
                workspaceSessionID: r.workspaceSessionID, workspaceHostID: r.workspaceHostID,
                workspaceHostGeneration: r.workspaceHostGeneration),
            AgentPrincipalReference(agentInstanceID: r.agentInstanceID, runtimeSessionID: RuntimeSessionID(),
                workspaceSessionID: r.workspaceSessionID, workspaceHostID: r.workspaceHostID,
                workspaceHostGeneration: r.workspaceHostGeneration),
            AgentPrincipalReference(agentInstanceID: r.agentInstanceID, runtimeSessionID: r.runtimeSessionID,
                workspaceSessionID: WorkspaceSessionID(), workspaceHostID: r.workspaceHostID,
                workspaceHostGeneration: r.workspaceHostGeneration),
            AgentPrincipalReference(agentInstanceID: r.agentInstanceID, runtimeSessionID: r.runtimeSessionID,
                workspaceSessionID: r.workspaceSessionID, workspaceHostID: WorkspaceHostID(),
                workspaceHostGeneration: r.workspaceHostGeneration),
            AgentPrincipalReference(agentInstanceID: r.agentInstanceID, runtimeSessionID: r.runtimeSessionID,
                workspaceSessionID: r.workspaceSessionID, workspaceHostID: r.workspaceHostID,
                workspaceHostGeneration: WorkspaceHostGeneration()),
        ]
        for reference in mismatches { #expect(h.authority.resolve(reference) == nil) }
        #expect(h.authority.reference(forRuntime: RuntimeSessionID()) == nil)
    }

    @Test func inactiveLaunchCannotIssueReference() throws {
        let h = try PrincipalAuthorityHarness(active: false)
        defer { try? FileManager.default.removeItem(at: h.root) }
        #expect(h.authority.resolve(h.reference) == nil)
        #expect(h.authority.reference(forRuntime: h.session.id) == nil)
    }

    @Test func closeIsIrreversible() throws {
        let h = try PrincipalAuthorityHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        #expect(h.authority.resolve(h.reference) != nil)
        h.authority.close()
        h.authority.close()
        #expect(h.authority.resolve(h.reference) == nil)
        #expect(h.authority.reference(forRuntime: h.session.id) == nil)
    }

    @Test func restartAndDiskHistoryDoNotRestoreAuthority() throws {
        let h = try PrincipalAuthorityHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let restarted = WorkspacePrincipalAuthority(
            registry: h.registry, workspace: h.authority.workspace, host: h.authority.host
        )
        #expect(restarted.generation != h.authority.generation)
        #expect(restarted.resolve(h.reference) == nil)
        let empty = AgentInstanceRegistry(journal: .file(h.journal))
        let fresh = WorkspacePrincipalAuthority(
            registry: empty, workspace: h.authority.workspace, host: h.authority.host,
            generation: h.authority.generation
        )
        #expect(fresh.resolve(h.reference) == nil)
        #expect(fresh.reference(forRuntime: h.session.id) == nil)
    }
}
