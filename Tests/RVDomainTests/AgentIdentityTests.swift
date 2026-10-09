import Foundation
import Testing
@testable import RVDomain
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func makeProfile(
    id: String = "default",
    writeTrees: [String] = ["/work/out"]
) -> RuntimeResourceProfile {
    RuntimeResourceProfile(
        id: id,
        projects: ["/work"],
        agents: ["claude"],
        executableLinks: [RuntimeResourceProfile.ExecutableLink(name: "claude", target: "/usr/local/bin/claude")],
        readFiles: ["/etc/hosts"],
        readTrees: ["/usr"],
        writeTrees: writeTrees,
        credentials: [RuntimeResourceProfile.Credential(source: "src", destination: "dst")],
        environment: [RuntimeResourceProfile.Environment(name: "LANG", literalValue: "C")],
        keychain: [RuntimeResourceProfile.KeychainEntry(service: "svc", account: "acct", env: "TOKEN")]
    )
}

private func makeDefinition(
    id: String = "claude",
    displayName: String = "Claude",
    blurb: String = "coding agent",
    executableRequirement: ExecutableRequirement = ExecutableRequirement(allowsUnsigned: true),
    hookHost: HookHost? = .claude,
    agentTag: String? = "claude",
    resourceProfile: RuntimeResourceProfile? = nil,
    credentialBindings: [String] = ["agent-credentials"],
    requiredAssurance: ExecutableAssurance = .launchObserved,
    authorityCeiling: AgentAuthority = AgentAuthority(scopes: ["fs.read", "shell"])
) -> AgentDefinition {
    AgentDefinition(
        id: AgentDefinitionID(rawValue: id),
        displayName: displayName,
        blurb: blurb,
        executableRequirement: executableRequirement,
        hookHost: hookHost,
        agentTag: agentTag,
        resourceProfile: resourceProfile ?? makeProfile(),
        credentialBindings: credentialBindings,
        requiredAssurance: requiredAssurance,
        authorityCeiling: authorityCeiling
    )
}

private func makeInstance(
    authority: AgentAuthority = AgentAuthority(scopes: ["fs.read", "shell"])
) -> AgentInstance {
    AgentInstance(
        id: AgentInstanceID(),
        owner: OwnerPrincipal(uid: 501),
        definitionID: AgentDefinitionID(rawValue: "claude"),
        definitionRevision: AgentDefinitionRevision.resolve(makeDefinition()),
        workspaceSessionID: WorkspaceSessionID(),
        runtimeSessionID: RuntimeSessionID(),
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: 100),
        workloadProcess: RuntimeChildIdentity(pid: 101),
        parent: nil,
        effectiveAuthority: authority,
        delegableAuthority: authority,
        mintedAt: Date(timeIntervalSince1970: 0)
    )
}

private func typeName<T>(of value: T) -> String {
    String(describing: T.self)
}

@Test func instanceIDs_areFreshAndUnguessable() {
    let first = AgentInstanceID()
    let second = AgentInstanceID()
    #expect(first != second)
    var seen: Set<AgentInstanceID> = []
    for _ in 0..<256 {
        seen.insert(AgentInstanceID())
    }
    #expect(seen.count == 256)
    let named = AgentInstanceID(rawValue: first.rawValue)
    #expect(named == first)
}

@Test func idTypes_areDistinct() {
    let uuid = UUID()
    let instance = AgentInstanceID(rawValue: uuid)
    let runtime = RuntimeSessionID(rawValue: uuid)
    let workspace = WorkspaceSessionID(rawValue: uuid)
    #expect(typeName(of: instance) != typeName(of: runtime))
    #expect(typeName(of: instance) != typeName(of: workspace))
    #expect(typeName(of: runtime) != typeName(of: workspace))
    #expect(AnyHashable(instance) != AnyHashable(runtime))
    #expect(AnyHashable(instance) != AnyHashable(workspace))
    #expect(AnyHashable(runtime) != AnyHashable(workspace))
}

@Test func revision_isStableForStableConfig() {
    let definition = makeDefinition()
    #expect(AgentDefinitionRevision.resolve(definition) == AgentDefinitionRevision.resolve(definition))
    #expect(AgentDefinitionRevision.resolve(makeDefinition()) == AgentDefinitionRevision.resolve(makeDefinition()))
}

@Test func revision_digestCaseVariantsResolveToOneRevision() {
    // Construction canonicalizes the pinned digest to lowercase hex,
    // so a case-variant pin matches instead of silently never matching.
    let lower = String(repeating: "ab", count: 32)
    let upper = lower.uppercased()
    let pinnedLower = makeDefinition(executableRequirement: ExecutableRequirement(
        expectedContentDigestSHA256: lower))
    let pinnedUpper = makeDefinition(executableRequirement: ExecutableRequirement(
        expectedContentDigestSHA256: upper))
    #expect(pinnedUpper.executableRequirement.expectedContentDigestSHA256 == lower)
    #expect(
        AgentDefinitionRevision.resolve(pinnedUpper)
            == AgentDefinitionRevision.resolve(pinnedLower))
}

@Test func revision_changesOnSecurityRelevantChange() {
    let baseline = AgentDefinitionRevision.resolve(makeDefinition())
    let variants: [AgentDefinition] = [
        makeDefinition(id: "codex"),
        makeDefinition(executableRequirement: ExecutableRequirement(
            expectedContentDigestSHA256: String(repeating: "a", count: 64),
            allowsUnsigned: true
        )),
        makeDefinition(executableRequirement: ExecutableRequirement(
            requiredTeamID: "TEAMID1234",
            allowsUnsigned: true
        )),
        makeDefinition(executableRequirement: ExecutableRequirement(
            requiredCodeRequirement: "identifier com.example.agent",
            allowsUnsigned: true
        )),
        makeDefinition(executableRequirement: ExecutableRequirement(allowsUnsigned: false)),
        makeDefinition(hookHost: .codex),
        makeDefinition(hookHost: nil),
        makeDefinition(agentTag: "codex"),
        makeDefinition(agentTag: nil),
        makeDefinition(credentialBindings: ["agent-credentials", "deploy-key"]),
        makeDefinition(requiredAssurance: .unattested),
        makeDefinition(authorityCeiling: AgentAuthority(scopes: ["fs.read"])),
    ]
    for variant in variants {
        #expect(
            AgentDefinitionRevision.resolve(variant) != baseline,
            "security-relevant change must change the revision"
        )
    }
}

@Test func revision_ignoresDisplayOnlyChange() {
    let baseline = AgentDefinitionRevision.resolve(makeDefinition())
    #expect(AgentDefinitionRevision.resolve(makeDefinition(displayName: "Claude Code")) == baseline)
    #expect(AgentDefinitionRevision.resolve(makeDefinition(blurb: "a different blurb")) == baseline)
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(displayName: "X", blurb: "Y")) == baseline
    )
}

@Test func revision_changesOnResourceProfileSecurityChange() {
    let baseline = AgentDefinitionRevision.resolve(makeDefinition())
    var profile = makeProfile()
    profile.writeTrees.append("/work/extra")
    #expect(AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: profile)) != baseline)
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: makeProfile(id: "other")))
            != baseline
    )
    var readProfile = makeProfile()
    readProfile.readFiles.append("/etc/passwd")
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: readProfile)) != baseline
    )
    var credentialProfile = makeProfile()
    credentialProfile.credentials.append(
        RuntimeResourceProfile.Credential(source: "other", destination: "here")
    )
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: credentialProfile)) != baseline
    )
    var envProfile = makeProfile()
    envProfile.environment.append(
        RuntimeResourceProfile.Environment(name: "EXTRA", literalValue: "yes")
    )
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: envProfile)) != baseline
    )
    var keychainProfile = makeProfile()
    keychainProfile.keychain.append(
        RuntimeResourceProfile.KeychainEntry(service: "other", account: "acct", env: "OTHER")
    )
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: keychainProfile)) != baseline
    )
    var projectsProfile = makeProfile()
    projectsProfile.projects.append("/other")
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: projectsProfile)) != baseline
    )
    var agentsProfile = makeProfile()
    agentsProfile.agents.append("codex")
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: agentsProfile)) != baseline
    )
    var linksProfile = makeProfile()
    linksProfile.executableLinks.append(
        RuntimeResourceProfile.ExecutableLink(name: "codex", target: "/usr/local/bin/codex")
    )
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: linksProfile)) != baseline
    )
    var treesProfile = makeProfile()
    treesProfile.readTrees.append("/bin")
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: treesProfile)) != baseline
    )
}

@Test func revision_treatsBindingsAsOrderInsignificantSets() {
    let baseline = AgentDefinitionRevision.resolve(makeDefinition())
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(
            credentialBindings: ["agent-credentials"],
            authorityCeiling: AgentAuthority(scopes: ["shell", "fs.read"])
        )) == baseline
    )
    var profile = makeProfile(writeTrees: ["/work/out"])
    profile.readTrees = ["/usr", "/bin"]
    let reordered = makeDefinition(resourceProfile: profile)
    var flipped = makeProfile(writeTrees: ["/work/out"])
    flipped.readTrees = ["/bin", "/usr"]
    #expect(
        AgentDefinitionRevision.resolve(reordered)
            == AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: flipped))
    )
}

@Test func revision_ordersListsByUTF8Bytes() {
    let composed = "caf\u{E9}"
    let decomposed = "cafe\u{301}"
    #expect(composed == decomposed)
    let left = makeDefinition(credentialBindings: [composed, decomposed, "a"])
    let right = makeDefinition(credentialBindings: ["a", decomposed, composed])
    #expect(AgentDefinitionRevision.resolve(left) == AgentDefinitionRevision.resolve(right))
    #expect(
        AgentAuthority(scopes: [decomposed, composed]).scopes
            == AgentAuthority(scopes: [composed, decomposed]).scopes
    )
}

@Test func revision_distinguishesAmbiguousEncodings() {
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(credentialBindings: []))
            != AgentDefinitionRevision.resolve(makeDefinition(credentialBindings: [""]))
    )
    var emptyAgents = makeProfile()
    emptyAgents.agents = []
    var blankAgent = makeProfile()
    blankAgent.agents = [""]
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: emptyAgents))
            != AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: blankAgent))
    )
    var dashHost = makeProfile()
    dashHost.environment = [RuntimeResourceProfile.Environment(name: "X", hostVariable: "-")]
    var dashLiteral = makeProfile()
    dashLiteral.environment = [RuntimeResourceProfile.Environment(name: "X", literalValue: "-")]
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: dashHost))
            != AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: dashLiteral))
    )
    var nilField = makeProfile()
    nilField.keychain = [RuntimeResourceProfile.KeychainEntry(service: "svc", account: "acct", env: "TOKEN")]
    var dashField = makeProfile()
    dashField.keychain = [
        RuntimeResourceProfile.KeychainEntry(service: "svc", account: "acct", field: "-", env: "TOKEN")
    ]
    #expect(
        AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: nilField))
            != AgentDefinitionRevision.resolve(makeDefinition(resourceProfile: dashField))
    )
}

@Test func delegation_narrowAccepted() throws {
    let parent = makeInstance()
    let child = try #require(parent.makeDelegatedChild(
        authority: AgentAuthority(scopes: ["fs.read"]),
        runtimeSessionID: RuntimeSessionID(),
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: 200),
        workloadProcess: nil,
        mintedAt: Date(timeIntervalSince1970: 1)
    ))
    #expect(child.id != parent.id)
    #expect(child.runtimeSessionID != parent.runtimeSessionID)
    #expect(child.parent?.parentInstanceID == parent.id)
    #expect(child.parent?.delegatedAuthority == AgentAuthority(scopes: ["fs.read"]))
    #expect(child.effectiveAuthority == AgentAuthority(scopes: ["fs.read"]))
    #expect(child.delegableAuthority == AgentAuthority(scopes: ["fs.read"]))
    #expect(child.owner == parent.owner)
    #expect(child.workspaceSessionID == parent.workspaceSessionID)
}

@Test func delegation_equalAccepted() throws {
    let parent = makeInstance()
    let same = AgentAuthority(scopes: ["fs.read", "shell"])
    let child = try #require(parent.makeDelegatedChild(
        authority: same,
        runtimeSessionID: RuntimeSessionID(),
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: 200),
        workloadProcess: nil,
        mintedAt: Date(timeIntervalSince1970: 1)
    ))
    #expect(child.parent?.parentInstanceID == parent.id)
    #expect(child.effectiveAuthority == same)
}

@Test func delegation_widenedRejected() {
    let parent = makeInstance()
    #expect(parent.makeDelegatedChild(
        authority: AgentAuthority(scopes: ["fs.read", "shell", "net.admin"]),
        runtimeSessionID: RuntimeSessionID(),
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: 200),
        workloadProcess: nil,
        mintedAt: Date(timeIntervalSince1970: 1)
    ) == nil)
    #expect(parent.makeDelegatedChild(
        authority: AgentAuthority(scopes: ["unrelated"]),
        runtimeSessionID: RuntimeSessionID(),
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: 200),
        workloadProcess: nil,
        mintedAt: Date(timeIntervalSince1970: 1)
    ) == nil)
}

@Test func delegation_childCarriesNoParentCredential() throws {
    let parent = makeInstance()
    let child = try #require(parent.makeDelegatedChild(
        authority: AgentAuthority(scopes: ["fs.read"]),
        runtimeSessionID: RuntimeSessionID(),
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: 200),
        workloadProcess: nil,
        mintedAt: Date(timeIntervalSince1970: 1)
    ))
    #expect(child.delegableAuthority.contains(AgentAuthority(scopes: ["shell"])) == false)
    #expect(child.parent?.delegatedAuthority.scopes == ["fs.read"])
    #expect(parent.effectiveAuthority == AgentAuthority(scopes: ["fs.read", "shell"]))
    #expect(parent.parent == nil)
}

@Test func digest_matchesSHA256StandardVectors() {
    #expect(
        HTTPDigest.sha256Hex([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    #expect(
        HTTPDigest.sha256Hex(Array("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
    #expect(
        HTTPDigest.sha256Hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    )
}

@Test func validity_transitionsMoveOneWayTowardInactive() {
    #expect(AgentInstanceValidity.active.transition(.beginRevoking) == .revoking)
    #expect(AgentInstanceValidity.active.transition(.didDeactivate) == .inactive)
    #expect(AgentInstanceValidity.revoking.transition(.didDeactivate) == .inactive)
    #expect(AgentInstanceValidity.unknown.transition(.didDeactivate) == .inactive)
    #expect(AgentInstanceValidity.unknown.transition(.beginRevoking) == nil)
    #expect(AgentInstanceValidity.revoking.transition(.beginRevoking) == nil)
    #expect(AgentInstanceValidity.inactive.transition(.beginRevoking) == nil)
    #expect(AgentInstanceValidity.inactive.transition(.didDeactivate) == nil)
}

@Test func validity_establishMovesInactiveToActiveOnly() {
    #expect(AgentInstanceValidity.inactive.transition(.didEstablish) == .active)
    #expect(AgentInstanceValidity.active.transition(.didEstablish) == nil)
    #expect(AgentInstanceValidity.revoking.transition(.didEstablish) == nil)
    #expect(AgentInstanceValidity.unknown.transition(.didEstablish) == nil)
}

@Test func ledger_activationDecidesOverExplicitValues() {
    let announced = AgentInstanceLedger.Record(
        validity: .inactive, finished: false, teardownClaimed: false
    )
    #expect(
        AgentInstanceLedger.decideActivate(announced, bindingMatches: true)
            == .establish(next: .active)
    )
    #expect(
        AgentInstanceLedger.decideActivate(announced, bindingMatches: false) == .refuse
    )
    let live = AgentInstanceLedger.Record(
        validity: .active, finished: false, teardownClaimed: false
    )
    #expect(AgentInstanceLedger.decideActivate(live, bindingMatches: true) == .alreadyActive)
    #expect(AgentInstanceLedger.decideActivate(live, bindingMatches: false) == .refuse)
    for validity in [AgentInstanceValidity.active, .revoking, .inactive, .unknown] {
        for (finished, claimed) in [(true, false), (false, true), (true, true)] {
            let dead = AgentInstanceLedger.Record(
                validity: validity, finished: finished, teardownClaimed: claimed
            )
            #expect(AgentInstanceLedger.decideActivate(dead, bindingMatches: true) == .refuse)
        }
    }
    let revoking = AgentInstanceLedger.Record(
        validity: .revoking, finished: false, teardownClaimed: false
    )
    #expect(AgentInstanceLedger.decideActivate(revoking, bindingMatches: true) == .refuse)
    let unknown = AgentInstanceLedger.Record(
        validity: .unknown, finished: false, teardownClaimed: false
    )
    #expect(AgentInstanceLedger.decideActivate(unknown, bindingMatches: true) == .refuse)
}

@Test func ledger_revokeClaimNamesNeverActivePath() {
    let live = AgentInstanceLedger.Record(
        validity: .active, finished: false, teardownClaimed: false
    )
    #expect(
        AgentInstanceLedger.decideRevokeClaim(live) == .beginRevoking(next: .revoking)
    )
    for validity in [AgentInstanceValidity.revoking, .inactive, .unknown] {
        let announced = AgentInstanceLedger.Record(
            validity: validity, finished: false, teardownClaimed: false
        )
        #expect(AgentInstanceLedger.decideRevokeClaim(announced) == .neverActive)
    }
    for validity in [AgentInstanceValidity.active, .revoking, .inactive, .unknown] {
        let claimed = AgentInstanceLedger.Record(
            validity: validity, finished: false, teardownClaimed: true
        )
        #expect(AgentInstanceLedger.decideRevokeClaim(claimed) == .refuse)
    }
}

@Test func ledger_revokeFinishConfirmsInactiveExplicitly() {
    for validity in [AgentInstanceValidity.active, .revoking, .unknown] {
        let record = AgentInstanceLedger.Record(
            validity: validity, finished: false, teardownClaimed: true
        )
        #expect(
            AgentInstanceLedger.decideRevokeFinish(record) == .deactivate(next: .inactive)
        )
    }
    let neverActive = AgentInstanceLedger.Record(
        validity: .inactive, finished: false, teardownClaimed: true
    )
    #expect(AgentInstanceLedger.decideRevokeFinish(neverActive) == .confirmInactive)
    for validity in [AgentInstanceValidity.active, .revoking, .inactive, .unknown] {
        let finished = AgentInstanceLedger.Record(
            validity: validity, finished: true, teardownClaimed: true
        )
        #expect(AgentInstanceLedger.decideRevokeFinish(finished) == .alreadyFinished)
    }
}

@Test func status_transitionsAreForwardOnly() {
    #expect(AgentInstanceStatus.establishing.transition(.becameActive) == .active)
    #expect(AgentInstanceStatus.establishing.transition(.didFinish) == .finished)
    #expect(AgentInstanceStatus.active.transition(.didFinish) == .finished)
    #expect(AgentInstanceStatus.active.transition(.becameActive) == nil)
    #expect(AgentInstanceStatus.finished.transition(.becameActive) == nil)
    #expect(AgentInstanceStatus.finished.transition(.didFinish) == nil)
}

@Test func owner_currentIsKernelDerived() {
    #expect(OwnerPrincipal.current() == OwnerPrincipal.current())
    #expect(OwnerPrincipal.current().uid == getuid())
    #expect(OwnerPrincipal(uid: 501).uid == 501)
}

@Test func authenticatedContext_usabilityFollowsValidity() {
    let instance = makeInstance()
    #expect(AuthenticatedAgentContext(instance: instance, validity: .active).isUsable)
    #expect(AuthenticatedAgentContext(instance: instance, validity: .revoking).isUsable == false)
    #expect(AuthenticatedAgentContext(instance: instance, validity: .inactive).isUsable == false)
    #expect(AuthenticatedAgentContext(instance: instance, validity: .unknown).isUsable == false)
}

@Test func definitionID_validatesOperatorNames() {
    #expect(AgentDefinitionID(validating: "claude") != nil)
    #expect(AgentDefinitionID(validating: "codex-1.0_x") != nil)
    #expect(AgentDefinitionID(validating: "") == nil)
    #expect(AgentDefinitionID(validating: "has space") == nil)
    #expect(AgentDefinitionID(validating: "slash/name") == nil)
    #expect(AgentDefinitionID(validating: String(repeating: "a", count: 33)) == nil)
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(AgentDefinitionID.self, from: Data("\"has space\"".utf8))
    }
}

@Test func authority_narrowsBySubset() {
    let wide = AgentAuthority(scopes: ["fs.read", "shell"])
    #expect(wide.contains(AgentAuthority(scopes: [])))
    #expect(wide.contains(wide))
    #expect(wide.contains(AgentAuthority(scopes: ["shell"])))
    #expect(wide.contains(AgentAuthority(scopes: ["shell", "net.admin"])) == false)
    #expect(AgentAuthority(scopes: []).contains(wide) == false)
    #expect(AgentAuthority(scopes: ["shell", "fs.read", "shell"]).scopes == ["fs.read", "shell"])
}

@Test func assurance_reportsOnlyWeakOrUnattested() {
    #expect(Set(ExecutableAssurance.allCases) == [.unattested, .launchObserved])
    #expect(ExecutableAssurance(rawValue: "unattested") == .unattested)
    #expect(ExecutableAssurance(rawValue: "launchObserved") == .launchObserved)
    #expect(ExecutableAssurance(rawValue: "strong") == nil)
    #expect(ExecutableAssurance(rawValue: "digestVerified") == nil)
    #expect(ExecutableAssurance(rawValue: "signatureVerified") == nil)
}

private func makeBindingSession(
    runtime: RuntimeSessionID,
    workspace: WorkspaceSessionID
) -> RuntimeSession {
    RuntimeSession(
        id: runtime,
        workspaceSessionID: workspace,
        host: .opencode,
        workspace: WorkingDirectory(validating: "/tmp/rv-identity")!,
        backend: .seatbelt,
        startedAt: Date(timeIntervalSince1970: 0),
        child: nil
    )
}

private func makeBindingFrame(
    session: RuntimeSession,
    capability: RuntimeCapability
) -> RuntimeActionFrame {
    RuntimeActionFrame(
        version: 1,
        requestID: RuntimeActionRequestID(validating: UUID().uuidString)!,
        capability: capability,
        claimedSession: RuntimeSessionClaim(validating: session.id.rawValue.uuidString)!,
        action: .shell(ShellCommand(rawValue: "touch marker"))
    )
}

private func makeBindingInstance(
    workspace: WorkspaceSessionID,
    runtime: RuntimeSessionID
) -> AgentInstance {
    AgentInstance(
        id: AgentInstanceID(),
        owner: OwnerPrincipal(uid: 501),
        definitionID: AgentDefinitionID(rawValue: "claude"),
        definitionRevision: AgentDefinitionRevision.resolve(makeDefinition()),
        workspaceSessionID: workspace,
        runtimeSessionID: runtime,
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: 100),
        workloadProcess: nil,
        parent: nil,
        effectiveAuthority: AgentAuthority(scopes: ["fs.read", "shell"]),
        delegableAuthority: AgentAuthority(scopes: ["fs.read", "shell"]),
        mintedAt: Date(timeIntervalSince1970: 0)
    )
}

@Test func establishedSession_bindsMatchingPairOnly() {
    let workspace = WorkspaceSessionID()
    let runtime = RuntimeSessionID()
    let instance = makeBindingInstance(workspace: workspace, runtime: runtime)
    let session = makeBindingSession(runtime: runtime, workspace: workspace)
    #expect(EstablishedRuntimeSession(session: session, instance: instance, establishedAt: Date()) != nil)
    let otherRuntime = makeBindingSession(runtime: RuntimeSessionID(), workspace: workspace)
    #expect(
        EstablishedRuntimeSession(session: otherRuntime, instance: instance, establishedAt: Date())
            == nil
    )
    let otherWorkspace = makeBindingSession(runtime: runtime, workspace: WorkspaceSessionID())
    #expect(
        EstablishedRuntimeSession(session: otherWorkspace, instance: instance, establishedAt: Date())
            == nil
    )
    let otherInstance = makeBindingInstance(workspace: workspace, runtime: runtime)
    #expect(EstablishedRuntimeSession(
        session: session, instance: otherInstance, establishedAt: Date()
    )?.agentInstanceID == otherInstance.id)
}

@Test func gate_boundChannelRequiresMatchingLiveContext() {
    let workspace = WorkspaceSessionID()
    let runtime = RuntimeSessionID()
    let instance = makeBindingInstance(workspace: workspace, runtime: runtime)
    let session = makeBindingSession(runtime: runtime, workspace: workspace)
    let capability = RuntimeCapability()
    let active = AuthenticatedAgentContext(instance: instance, validity: .active)

    // Matching live context proceeds past the principal check: the failing
    // proposal proves authentication accepted, and the event is attributed.
    var bound: RuntimeChannelBinding? = RuntimeChannelBinding(
        session: session, capability: capability, agentInstanceID: instance.id
    )
    let admitted = RuntimeAdmissionGate.submitLegacy(
        binding: &bound,
        frame: .success(makeBindingFrame(session: session, capability: capability)),
        agentContext: active
    ) { _ in .failure(.failed) }
    #expect(admitted.response == .evaluationFailed)
    #expect(admitted.event.agentInstance == instance.id.rawValue.uuidString)
    #expect(admitted.event.agentDefinition == "claude")

    // No trusted context: perfect payload, missing principal.
    var missing: RuntimeChannelBinding? = RuntimeChannelBinding(
        session: session, capability: capability, agentInstanceID: instance.id
    )
    let unknown = RuntimeAdmissionGate.submitLegacy(
        binding: &missing,
        frame: .success(makeBindingFrame(session: session, capability: capability))
    ) { _ in .failure(.failed) }
    #expect(unknown.response == .rejected(.principalRequired))
    #expect(unknown.event.agentInstance == instance.id.rawValue.uuidString)
    #expect(unknown.event.agentDefinition == nil)

    // Stale or dead validity fails closed.
    for validity in [AgentInstanceValidity.revoking, .inactive, .unknown] {
        var dead: RuntimeChannelBinding? = RuntimeChannelBinding(
            session: session, capability: capability, agentInstanceID: instance.id
        )
        let context = AuthenticatedAgentContext(instance: instance, validity: validity)
        let decision = RuntimeAdmissionGate.submitLegacy(
            binding: &dead,
            frame: .success(makeBindingFrame(session: session, capability: capability)),
            agentContext: context
        ) { _ in .failure(.failed) }
        #expect(decision.response == .rejected(.inactiveSession))
    }

    // A live context for a different instance is impersonation.
    let other = makeBindingInstance(workspace: workspace, runtime: RuntimeSessionID())
    var crossed: RuntimeChannelBinding? = RuntimeChannelBinding(
        session: session, capability: capability, agentInstanceID: instance.id
    )
    let crossedDecision = RuntimeAdmissionGate.submitLegacy(
        binding: &crossed,
        frame: .success(makeBindingFrame(session: session, capability: capability)),
        agentContext: AuthenticatedAgentContext(instance: other, validity: .active)
    ) { _ in .failure(.failed) }
    #expect(crossedDecision.response == .rejected(.impersonation))
    // The smuggled context is unverified: the rejection attributes the
    // RV-held channel binding, never the presented foreign principal.
    #expect(crossedDecision.event.agentInstance == instance.id.rawValue.uuidString)
    #expect(crossedDecision.event.agentInstance != other.id.rawValue.uuidString)
    #expect(crossedDecision.event.agentDefinition == nil)

    // Legacy channels carry no principal and keep the old behavior.
    var legacy: RuntimeChannelBinding? = RuntimeChannelBinding(
        session: session, capability: capability
    )
    let legacyDecision = RuntimeAdmissionGate.submitLegacy(
        binding: &legacy,
        frame: .success(makeBindingFrame(session: session, capability: capability))
    ) { _ in .failure(.failed) }
    #expect(legacyDecision.response == .evaluationFailed)
    #expect(legacyDecision.event.agentInstance == nil)
    #expect(legacyDecision.event.agentDefinition == nil)
}

@Test func gate_legacyAcceptStampsNoUnverifiedContext() {
    // A legacy channel names no instance, so a presented context is
    // unverified even when authentication accepts: the audit event must
    // not attribute it.
    let workspace = WorkspaceSessionID()
    let runtime = RuntimeSessionID()
    let session = makeBindingSession(runtime: runtime, workspace: workspace)
    let capability = RuntimeCapability()
    let foreign = makeBindingInstance(workspace: workspace, runtime: RuntimeSessionID())
    var legacy: RuntimeChannelBinding? = RuntimeChannelBinding(
        session: session, capability: capability
    )
    let decision = RuntimeAdmissionGate.submitLegacy(
        binding: &legacy,
        frame: .success(makeBindingFrame(session: session, capability: capability)),
        agentContext: AuthenticatedAgentContext(instance: foreign, validity: .active)
    ) { _ in .failure(.failed) }
    #expect(decision.response == .evaluationFailed)
    #expect(decision.event.agentInstance == nil)
    #expect(decision.event.agentDefinition == nil)
}

@Test func gate_subjectCarriesTrustedContextPayloadsCannotSet() {
    let workspace = WorkspaceSessionID()
    let runtime = RuntimeSessionID()
    let instance = makeBindingInstance(workspace: workspace, runtime: runtime)
    let session = makeBindingSession(runtime: runtime, workspace: workspace)
    let trusted = AuthenticatedAgentContext(instance: instance, validity: .active)
    let subject = RuntimeAdmissionSubject(
        session: session,
        policyWorkspace: session.workspace,
        agent: trusted
    )
    #expect(subject.agent == trusted)
    #expect(RuntimeAdmissionSubject(session: session, policyWorkspace: session.workspace).agent == nil)
}
