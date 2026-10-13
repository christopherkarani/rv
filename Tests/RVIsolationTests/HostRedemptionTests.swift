#if os(macOS)
import Darwin
import Foundation
import RVDomain
import RVIPC
import Synchronization
import Testing
@testable import RVIsolation
@testable import RVPolicy

private func redeemSupervisor(_ tree: ContainmentTree) throws -> WorkspaceSessionSupervisor {
    try WorkspaceSessionSupervisor.open(
        try #require(WorkingDirectory(validating: tree.workspaceURL.path)),
        lifecycleLog: .file(tree.rootURL.appendingPathComponent("workspace.jsonl")),
        runtimeLog: tree.rootURL.appendingPathComponent("runtimes.jsonl"),
        instanceJournal: .file(tree.rootURL.appendingPathComponent("instances.jsonl"))
    ).get()
}

private func redeemDefinition(
    id: String = "redeem-agent",
    target: String = "/bin/sleep",
    projects: [String],
    assurance: ExecutableAssurance = .launchObserved,
    environment: [RuntimeResourceProfile.Environment] = []
) -> AgentDefinition {
    AgentDefinition(
        id: AgentDefinitionID(rawValue: id),
        displayName: "Redeem agent",
        blurb: "",
        executableRequirement: ExecutableRequirement(allowsUnsigned: true),
        hookHost: nil,
        agentTag: nil,
        resourceProfile: RuntimeResourceProfile(
            id: "redeem",
            projects: projects,
            executableLinks: [.init(name: id, target: target)],
            environment: environment
        ),
        credentialBindings: [],
        requiredAssurance: assurance,
        authorityCeiling: .none
    )
}

private func redeemNamedSelection(_ definition: AgentDefinition) -> ResolvedAgentLaunch {
    ResolvedAgentLaunch(
        resolved: ResolvedAgentDefinition(
            definition: definition,
            revision: AgentDefinitionRevision.resolve(definition)
        ),
        executable: definition.resourceProfile.executableLinks.first(where: {
            $0.name == definition.id.rawValue
        })?.target ?? "/bin/sleep",
        resourceProfile: definition.resourceProfile
    )
}

private func redeemCommit(
    authorizationID: UUID = UUID(),
    prepared: PreparedWorkspaceLaunch,
    definition: AgentDefinition? = nil
) -> HostRedemptionCommit {
    let kind: HostRedemptionKind
    let definitionID: AgentDefinitionID?
    let revision: AgentDefinitionRevision?
    switch prepared.intent.target {
    case .named:
        kind = .launchAgent
        definitionID = definition?.id ?? prepared.selection.resolved.definition.id
        revision = definition.map { AgentDefinitionRevision.resolve($0) }
            ?? prepared.selection.resolved.revision
    case .custom:
        kind = .launchCustom
        definitionID = nil
        revision = nil
    }
    return HostRedemptionCommit(
        authorizationID: authorizationID,
        workspace: prepared.binding.workspace,
        host: prepared.binding.host,
        generation: prepared.binding.generation,
        preparedID: prepared.binding.preparedLaunchID,
        intentDigest: prepared.intentDigest,
        kind: kind,
        definitionID: definitionID,
        definitionRevision: revision)
}

private func redeemFailedError(_ result: HostRedemptionResult) -> WorkspaceSessionError? {
    guard case .failed(_, let error) = result else { return nil }
    return error
}

private func redeemAccepted(_ result: HostRedemptionResult) -> Bool? {
    guard case .failed(let accepted, _) = result else { return nil }
    return accepted
}

/// Host redemption: acceptance fence, binding checks, cwd revalidation,
/// retained-state dispatch, and replay safety. Real supervisors and real
/// contained children; serialized like the other supervisor suites.
@Suite(.serialized)
struct HostRedemptionTests {
    @Test func namedRedemptionLaunchesExactlyOnce() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let outcome = supervisor.redeemPreparedLaunch(
            commit: redeemCommit(prepared: prepared),
            sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-runtime.jsonl")),
            admission: .failClosed)
        guard case .launched(let runtime, let instance) = outcome else {
            Issue.record("expected launch, got \(outcome)")
            return
        }
        // Fresh runtime identity, never a prepared ID.
        #expect(runtime.rawValue != prepared.binding.preparedLaunchID.rawValue)
        let live = try #require(supervisor.agentInstances.instance(forRuntime: runtime))
        #expect(live.id == instance)
        #expect(live.definitionID == definition.id)
        #expect(live.definitionRevision == AgentDefinitionRevision.resolve(definition))
        #expect(live.workspaceSessionID == supervisor.id)
        #expect(live.runtimeSessionID == runtime)
        #expect(live.assurance == .launchObserved)
        #expect(live.executableEvidence.contentDigestSHA256 == nil)
        try supervisor.cancel(runtime).get()
    }

    @Test func customRedemptionKeepsBaseFence() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        // M4: custom preparation measures the executable against the
        // authorized digest; the fixture authorizes the real bytes.
        let sleepDigest = try #require(RVFileDigest.sha256HexOfFile(atPath: "/bin/sleep"))
        let selection = try AgentLaunchSelection.resolveCustom(
            executable: "/bin/sleep",
            expectedContentDigestSHA256: sleepDigest).get()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let outcome = supervisor.redeemPreparedLaunch(
            commit: redeemCommit(prepared: prepared),
            sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-custom.jsonl")),
            admission: .failClosed)
        guard case .launched(let runtime, let instance) = outcome else {
            Issue.record("expected launch, got \(outcome)")
            return
        }
        let live = try #require(supervisor.agentInstances.instance(forRuntime: runtime))
        #expect(live.id == instance)
        #expect(live.definitionID.rawValue == AgentDefinitionStore.reservedSnapshotID)
        #expect(live.effectiveAuthority == .none)
        #expect(live.assurance == .launchObserved)
        try supervisor.cancel(runtime).get()
    }

    @Test func redemptionRefusesSwappedExecutableBytes() throws {
        // M4: the spawn commit re-measures the custom executable adjacent
        // to spawn, so bytes swapped after preparation still refuse and
        // no process runs.
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let script = tree.rootURL.appendingPathComponent("swap-target.sh")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: script)
        let digest = try #require(RVFileDigest.sha256HexOfFile(atPath: script.path))
        let selection = try AgentLaunchSelection.resolveCustom(
            executable: script.path,
            expectedContentDigestSHA256: digest).get()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: [], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        try Data("#!/bin/sh\necho pwned\n".utf8).write(to: script)
        let outcome = supervisor.redeemPreparedLaunch(
            commit: redeemCommit(prepared: prepared),
            sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-swap.jsonl")),
            admission: .failClosed)
        guard case .failed(let accepted, let error) = outcome else {
            Issue.record("swapped bytes must refuse, got \(outcome)")
            return
        }
        #expect(accepted == true)
        #expect(error == .unknownPreparedLaunch)
    }

    @Test func bindingMatrixRejectsSingleFieldMutations() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let honest = redeemCommit(prepared: prepared)
        func commit(
            workspace: WorkspaceSessionID = honest.workspace,
            host: WorkspaceHostID = honest.host,
            generation: WorkspaceHostGeneration = honest.generation,
            preparedID: PreparedLaunchID = honest.preparedID,
            digest: WorkspaceLaunchIntentDigest = honest.intentDigest,
            kind: HostRedemptionKind = honest.kind,
            definitionID: AgentDefinitionID? = honest.definitionID,
            revision: AgentDefinitionRevision? = honest.definitionRevision
        ) -> HostRedemptionCommit {
            HostRedemptionCommit(
                authorizationID: UUID(), workspace: workspace, host: host,
                generation: generation, preparedID: preparedID,
                intentDigest: digest, kind: kind,
                definitionID: definitionID, definitionRevision: revision)
        }
        let otherRevision = AgentDefinitionRevision(digestHex: String(repeating: "d", count: 64))
        let mutants: [HostRedemptionCommit] = [
            commit(workspace: WorkspaceSessionID()),
            commit(host: WorkspaceHostID()),
            commit(generation: WorkspaceHostGeneration()),
            commit(preparedID: PreparedLaunchID()),
            commit(digest: WorkspaceLaunchIntentDigest(
                sha256Hex: String(repeating: "e", count: 64))),
            commit(kind: .launchCustom, definitionID: nil, revision: nil),
            commit(definitionID: AgentDefinitionID(rawValue: "other-agent")),
            commit(revision: otherRevision),
        ]
        for mutant in mutants {
            let outcome = supervisor.redeemPreparedLaunch(
                commit: mutant,
                sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-matrix.jsonl")),
                admission: .failClosed)
            #expect(redeemAccepted(outcome) == false)
            #expect(redeemFailedError(outcome) == .unknownPreparedLaunch)
        }
        // Every refusal spent nothing: the honest commit still launches.
        let launched = supervisor.redeemPreparedLaunch(
            commit: honest,
            sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-matrix.jsonl")),
            admission: .failClosed)
        guard case .launched(let runtime, _) = launched else {
            Issue.record("honest commit must launch after refusals: \(launched)")
            return
        }
        try supervisor.cancel(runtime).get()
    }

    @Test func customCommitRejectsDefinitionUpgrade() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        // M4: custom preparation measures the executable against the
        // authorized digest; the fixture authorizes the real bytes.
        let sleepDigest = try #require(RVFileDigest.sha256HexOfFile(atPath: "/bin/sleep"))
        let selection = try AgentLaunchSelection.resolveCustom(
            executable: "/bin/sleep",
            expectedContentDigestSHA256: sleepDigest).get()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let honest = redeemCommit(prepared: prepared)
        // A custom prepared operation with a named-looking commit, and a
        // custom commit carrying definition bindings: both refuse.
        let namedShaped = HostRedemptionCommit(
            authorizationID: UUID(), workspace: honest.workspace, host: honest.host,
            generation: honest.generation, preparedID: honest.preparedID,
            intentDigest: honest.intentDigest, kind: .launchAgent,
            definitionID: AgentDefinitionID(rawValue: "redeem-agent"),
            definitionRevision: AgentDefinitionRevision(
                digestHex: String(repeating: "d", count: 64)))
        let upgraded = HostRedemptionCommit(
            authorizationID: UUID(), workspace: honest.workspace, host: honest.host,
            generation: honest.generation, preparedID: honest.preparedID,
            intentDigest: honest.intentDigest, kind: .launchCustom,
            definitionID: AgentDefinitionID(rawValue: "redeem-agent"),
            definitionRevision: AgentDefinitionRevision(
                digestHex: String(repeating: "d", count: 64)))
        for mutant in [namedShaped, upgraded] {
            let outcome = supervisor.redeemPreparedLaunch(
                commit: mutant,
                sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-upgrade.jsonl")),
                admission: .failClosed)
            #expect(redeemAccepted(outcome) == false)
            #expect(redeemFailedError(outcome) == .unknownPreparedLaunch)
        }
        guard case .launched(let runtime, _) = supervisor.redeemPreparedLaunch(
            commit: honest,
            sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-upgrade.jsonl")),
            admission: .failClosed)
        else {
            Issue.record("honest custom commit must launch after refusals")
            return
        }
        try supervisor.cancel(runtime).get()
    }

    @Test func commitDTORequiresExactShape() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: [], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let honest = redeemCommit(prepared: prepared)
        func dto(
            kind: String = "launchAgent",
            digest: String = honest.intentDigest.sha256Hex,
            definitionID: String? = definition.id.rawValue,
            revision: String? = AgentDefinitionRevision.resolve(definition).digestHex
        ) -> HostRedeemCommitDTO {
            HostRedeemCommitDTO(
                authorizationID: honest.authorizationID,
                workspaceSessionID: honest.workspace.rawValue,
                hostID: honest.host.rawValue,
                generation: honest.generation.rawValue,
                preparedID: honest.preparedID.rawValue,
                intentDigestHex: digest, kind: kind,
                definitionID: definitionID, revisionDigest: revision)
        }
        #expect(HostRedemptionCommit(request: dto()) == honest)
        #expect(HostRedemptionCommit(request: dto(kind: "launch")) == nil)
        #expect(HostRedemptionCommit(request: dto(kind: "launchCustom")) == nil)
        #expect(HostRedemptionCommit(request: dto(digest: "short")) == nil)
        #expect(HostRedemptionCommit(request: dto(
            digest: String(repeating: "A", count: 64))) == nil)
        #expect(HostRedemptionCommit(request: dto(definitionID: nil)) == nil)
        #expect(HostRedemptionCommit(request: dto(revision: nil)) == nil)
        #expect(HostRedemptionCommit(request: dto(revision: "xyz")) == nil)
        #expect(HostRedemptionCommit(request: dto(definitionID: "")) == nil)
        let customDTO = HostRedeemCommitDTO(
            authorizationID: UUID(), workspaceSessionID: UUID(), hostID: UUID(),
            generation: UUID(), preparedID: UUID(),
            intentDigestHex: String(repeating: "a", count: 64),
            kind: "launchCustom", definitionID: nil, revisionDigest: nil)
        #expect(HostRedemptionCommit(request: customDTO) != nil)
        let upgradedCustom = HostRedeemCommitDTO(
            authorizationID: UUID(), workspaceSessionID: UUID(), hostID: UUID(),
            generation: UUID(), preparedID: UUID(),
            intentDigestHex: String(repeating: "a", count: 64),
            kind: "launchCustom", definitionID: "redeem-agent",
            revisionDigest: String(repeating: "a", count: 64))
        #expect(HostRedemptionCommit(request: upgradedCustom) == nil)
    }

    @Test func directDispatchConsumesThePreparedEntry() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let store = RuntimeSessionStore.file(
            tree.rootURL.appendingPathComponent("redeem-direct.jsonl"))
        let first = try supervisor.dispatchPreparedLaunch(
            prepared, sessionStore: store, admission: .failClosed).get()
        // Sequential re-dispatch of the same value fails: the entry was
        // consumed by the first establishment attempt.
        let second = supervisor.dispatchPreparedLaunch(
            prepared, sessionStore: store, admission: .failClosed)
        guard case .failure(let error) = second else {
            Issue.record("second direct dispatch must fail")
            try? supervisor.cancel(first.id).get()
            return
        }
        #expect(error == .unknownPreparedLaunch)
        try supervisor.cancel(first.id).get()
    }

    @Test func replayReturnsRecordedOutcomeWithoutSecondSpawn() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let commit = redeemCommit(prepared: prepared)
        let store = RuntimeSessionStore.file(
            tree.rootURL.appendingPathComponent("redeem-replay.jsonl"))
        guard case .launched(let firstRuntime, let firstInstance) =
            supervisor.redeemPreparedLaunch(
                commit: commit, sessionStore: store, admission: .failClosed)
        else {
            Issue.record("first redemption must launch")
            return
        }
        // Lost-reply replay: the recorded outcome returns verbatim.
        guard case .launched(let secondRuntime, let secondInstance) =
            supervisor.redeemPreparedLaunch(
                commit: commit, sessionStore: store, admission: .failClosed)
        else {
            Issue.record("replay must return the recorded launch")
            return
        }
        #expect(secondRuntime == firstRuntime)
        #expect(secondInstance == firstInstance)
        #expect(supervisor.agentInstances.instance(forRuntime: firstRuntime) != nil)
        try supervisor.cancel(firstRuntime).get()
    }

    @Test func failedOutcomeReplaysWithoutSecondAttempt() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let commit = redeemCommit(prepared: prepared)
        let store = RuntimeSessionStore.file(
            tree.rootURL.appendingPathComponent("redeem-failreplay.jsonl"))
        let first = supervisor.redeemPreparedLaunch(
            commit: commit, sessionStore: store, admission: .failClosed,
            spawnFault: .spawn)
        #expect(redeemAccepted(first) == true)
        #expect(redeemFailedError(first) == .apply(.processSpawnFailed))
        // The replay is the recorded coarse failure: spent, same
        // authorization, no second spawn attempt.
        let second = supervisor.redeemPreparedLaunch(
            commit: commit, sessionStore: store, admission: .failClosed,
            spawnFault: .spawn)
        #expect(redeemAccepted(second) == true)
        #expect(redeemFailedError(second) != nil)
    }

    @Test func concurrentRedemptionHasSingleWinner() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        for _ in 0..<2 {
            let definition = redeemDefinition(projects: [tree.workspaceURL.path])
            let prepared = try supervisor.prepareIdentityLaunch(
                selection: redeemNamedSelection(definition),
                arguments: ["30"], io: .discard,
                host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
            ).get()
            let commit = redeemCommit(prepared: prepared)
            let store = RuntimeSessionStore.file(
                tree.rootURL.appendingPathComponent("redeem-race-\(UUID().uuidString).jsonl"))
            let outcomes = Mutex<[HostRedemptionResult]>([])
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        let outcome = supervisor.redeemPreparedLaunch(
                            commit: commit, sessionStore: store,
                            admission: .failClosed)
                        outcomes.withLock { $0.append(outcome) }
                    }
                }
            }
            let seen = outcomes.withLock { $0 }
            #expect(seen.count == 16)
            let launchedRuntimes = Set(seen.compactMap { outcome -> RuntimeSessionID? in
                guard case .launched(let runtime, _) = outcome else { return nil }
                return runtime
            })
            // Exactly one dispatch: every launch reports the same runtime,
            // and every other attempt reports the in-flight acceptance.
            #expect(launchedRuntimes.count == 1)
            for outcome in seen {
                switch outcome {
                case .launched(let runtime, _):
                    #expect(launchedRuntimes.contains(runtime))
                case .failed(let accepted, let error):
                    #expect(accepted == true)
                    #expect(error == .redemptionAlreadyAccepted)
                }
            }
            if let runtime = launchedRuntimes.first {
                try supervisor.cancel(runtime).get()
            }
        }
    }

    @Test func acceptLoserAfterWinnerRecordsReturnsRecordedOutcome() throws {
        // A same-authorization duplicate that loses the accept race
        // after the winner recorded must receive the recorded outcome,
        // not a pre-accept refusal. The rendezvous forces the
        // record-before-recheck interleave deterministically: the loser
        // passes its entry checks and waits, the winner runs to
        // completion, then the loser proceeds to a failed accept with
        // the outcome already in the ledger.
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let commit = redeemCommit(prepared: prepared)
        let store = RuntimeSessionStore.file(
            tree.rootURL.appendingPathComponent("redeem-record-race.jsonl"))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let loserOutcome = Mutex<HostRedemptionResult?>(nil)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let outcome = supervisor.redeemPreparedLaunch(
                commit: commit, sessionStore: store,
                admission: .failClosed,
                preAcceptHook: {
                    entered.signal()
                    release.wait()
                })
            loserOutcome.withLock { $0 = outcome }
            group.leave()
        }
        entered.wait()
        let winner = supervisor.redeemPreparedLaunch(
            commit: commit, sessionStore: store, admission: .failClosed)
        guard case .launched(let runtime, let instance) = winner else {
            release.signal()
            group.wait()
            Issue.record("expected winner launch, got \(winner)")
            return
        }
        release.signal()
        group.wait()
        let loser = try #require(loserOutcome.withLock { $0 })
        guard case .launched(let loserRuntime, let loserInstance) = loser else {
            Issue.record("expected recorded launch, got \(loser)")
            try supervisor.cancel(runtime).get()
            return
        }
        #expect(loserRuntime == runtime)
        #expect(loserInstance == instance)
        try supervisor.cancel(runtime).get()
    }

    @Test func expiredPreparedRefusesWithoutSpending() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration(),
            timeToLive: -1
        ).get()
        let outcome = supervisor.redeemPreparedLaunch(
            commit: redeemCommit(prepared: prepared),
            sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-expired.jsonl")),
            admission: .failClosed)
        #expect(redeemAccepted(outcome) == false)
        #expect(redeemFailedError(outcome) == .unknownPreparedLaunch)
    }

    @Test func invalidatedPreparedRefuses() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        supervisor.invalidatePreparedLaunch(prepared.binding.preparedLaunchID)
        let outcome = supervisor.redeemPreparedLaunch(
            commit: redeemCommit(prepared: prepared),
            sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-invalid.jsonl")),
            admission: .failClosed)
        #expect(redeemAccepted(outcome) == false)
        #expect(redeemFailedError(outcome) == .unknownPreparedLaunch)
    }

    @Test func redeemAfterCloseRefuses() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        _ = supervisor.close()
        let outcome = supervisor.redeemPreparedLaunch(
            commit: redeemCommit(prepared: prepared),
            sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-closed.jsonl")),
            admission: .failClosed)
        #expect(redeemAccepted(outcome) == false)
        #expect(redeemFailedError(outcome) == .unknownPreparedLaunch)
    }

    @Test func storeAcceptanceFenceIsLinearizable() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let template = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let store = PreparedLaunchStore()
        let now = Date()
        #expect(store.insert(template, now: now))
        let id = template.binding.preparedLaunchID
        // Wrong cwd: refused, and the entry remains prepared.
        let wrongCwd = CwdIdentityStamp(
            resolvedPath: template.cwdIdentity.resolvedPath,
            device: template.cwdIdentity.device,
            inode: template.cwdIdentity.inode &+ 1,
            mountSource: template.cwdIdentity.mountSource)
        #expect(store.accept(id, now: now, liveCwd: wrongCwd, verifying: { _ in true }) == nil)
        #expect(store.isAccepted(id) == false)
        #expect(store.isUsable(id, now: now))
        // Failing predicate: refused, entry remains.
        #expect(store.accept(id, now: now, liveCwd: template.cwdIdentity, verifying: {
            _ in false
        }) == nil)
        #expect(store.isAccepted(id) == false)
        // Accept moves prepared→accepted exactly once.
        let retained = try #require(store.accept(
            id, now: now, liveCwd: template.cwdIdentity, verifying: { _ in true }))
        #expect(retained == template)
        #expect(store.isAccepted(id))
        #expect(store.isUsable(id, now: now) == false)
        #expect(store.accept(
            id, now: now, liveCwd: template.cwdIdentity, verifying: { _ in true }) == nil)
        // Neither invalidation nor close-all re-arms the acceptance.
        store.remove(id)
        #expect(store.isAccepted(id))
        store.invalidateAll()
        #expect(store.isAccepted(id))
        // Recording the outcome clears the marker atomically: a duplicate
        // always observes the marker or the outcome, never neither.
        let authorization = UUID()
        #expect(store.recordedResult(authorization: authorization) == nil)
        store.recordResult(
            authorization: authorization, preparedID: id, result: .failed)
        #expect(store.isAccepted(id) == false)
        // Results are first-write-wins and bounded FIFO.
        store.recordResult(
            authorization: authorization, preparedID: id,
            result: .launched(runtime: RuntimeSessionID(), instance: AgentInstanceID()))
        #expect(store.recordedResult(authorization: authorization) == .failed)
        for _ in 0..<PreparedLaunchLimits.maxRedemptionResults {
            store.recordResult(
                authorization: UUID(), preparedID: PreparedLaunchID(),
                result: .failed)
        }
        #expect(store.resultCount() == PreparedLaunchLimits.maxRedemptionResults)
        #expect(store.recordedResult(authorization: authorization) == nil)
    }

    @Test func storeAcceptDropsExpiredEntries() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let template = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let store = PreparedLaunchStore()
        let now = Date()
        #expect(store.insert(template, now: now))
        #expect(store.accept(
            template.binding.preparedLaunchID,
            now: now.addingTimeInterval(3600),
            liveCwd: template.cwdIdentity,
            verifying: { _ in true }) == nil)
        #expect(store.liveCount(now: now.addingTimeInterval(3600)) == 0)
    }

    @Test func cwdIdentityClosesSwapAndRecreate() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("rv-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let policy = try #require(WorkingDirectory(validating: directory.path))
        let captured = try #require(captureCwdIdentity(policyWorkspace: policy))
        // Untouched: identical.
        #expect(captureCwdIdentity(policyWorkspace: policy) == captured)
        // Rename away and recreate the same path: new inode, mismatch.
        let moved = root.appendingPathComponent("ws-moved", isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recreated = try #require(captureCwdIdentity(policyWorkspace: policy))
        #expect(recreated != captured)
        #expect(recreated.resolvedPath == captured.resolvedPath)
        #expect(recreated.inode != captured.inode)
        // Same filesystem: device and mount source are stable across the
        // recreation, so they pin the volume rather than the directory.
        #expect(recreated.device == captured.device)
        #expect(recreated.mountSource == captured.mountSource)
        #expect(captured.mountSource.isEmpty == false)
        // Symlink repointing: resolution changes, mismatch.
        let link = root.appendingPathComponent("link", isDirectory: false)
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: directory.path)
        let linkPolicy = try #require(WorkingDirectory(validating: link.path))
        let viaLink = try #require(captureCwdIdentity(policyWorkspace: linkPolicy))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: moved.path)
        #expect(captureCwdIdentity(policyWorkspace: linkPolicy) != viaLink)
        // Missing path and regular file: no identity, fail closed.
        let missing = try #require(WorkingDirectory(
            validating: root.appendingPathComponent("nope").path))
        #expect(captureCwdIdentity(policyWorkspace: missing) == nil)
        let file = root.appendingPathComponent("file", isDirectory: false)
        try Data("x".utf8).write(to: file)
        let filePolicy = try #require(WorkingDirectory(validating: file.path))
        #expect(captureCwdIdentity(policyWorkspace: filePolicy) == nil)
    }

    @Test func liveCwdVerificationIsExact() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("rv-cwdv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let policy = try #require(WorkingDirectory(validating: directory.path))
        let stamp = try #require(captureCwdIdentity(policyWorkspace: policy))
        // The exact helper the spawn body calls around `posix_spawn`.
        #expect(verifyLiveCwdIdentity(
            policyWorkspacePath: directory.path, expected: stamp))
        #expect(verifyLiveCwdIdentity(
            policyWorkspacePath: "", expected: stamp) == false)
        let tampered = CwdIdentityStamp(
            resolvedPath: stamp.resolvedPath, device: stamp.device,
            inode: stamp.inode, mountSource: "bogus-source")
        #expect(verifyLiveCwdIdentity(
            policyWorkspacePath: directory.path, expected: tampered) == false)
        // Recreate the path: verification fails against the old stamp.
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(verifyLiveCwdIdentity(
            policyWorkspacePath: directory.path, expected: stamp) == false)
        let fresh = try #require(captureCwdIdentity(policyWorkspace: policy))
        #expect(verifyLiveCwdIdentity(
            policyWorkspacePath: directory.path, expected: fresh))
    }

    @Test func cwdSwapRefusesAndRestoreRecovers() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let commit = redeemCommit(prepared: prepared)
        let store = RuntimeSessionStore.file(
            tree.rootURL.appendingPathComponent("redeem-cwd.jsonl"))
        // Move the workspace path away: live resolution fails, refuse.
        let workspacePath = tree.workspaceURL.path
        let parked = workspacePath + "-parked"
        try FileManager.default.moveItem(atPath: workspacePath, toPath: parked)
        do {
            let refused = supervisor.redeemPreparedLaunch(
                commit: commit, sessionStore: store, admission: .failClosed)
            #expect(redeemAccepted(refused) == false)
            #expect(redeemFailedError(refused) == .unknownPreparedLaunch)
            try FileManager.default.moveItem(atPath: parked, toPath: workspacePath)
        } catch {
            try? FileManager.default.moveItem(atPath: parked, toPath: workspacePath)
            throw error
        }
        // Restored: the refusal spent nothing, the launch proceeds.
        guard case .launched(let runtime, _) = supervisor.redeemPreparedLaunch(
            commit: commit, sessionStore: store, admission: .failClosed)
        else {
            Issue.record("redeem must succeed after cwd restore")
            return
        }
        try supervisor.cancel(runtime).get()
    }

    @Test func prePrepareSwapIsRefusedNotAdopted() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let selection = redeemNamedSelection(definition)
        // Plant a fake directory at the workspace path before preparation.
        let workspacePath = tree.workspaceURL.path
        let parked = workspacePath + "-parked"
        var restored = false
        defer {
            if restored == false {
                try? FileManager.default.removeItem(atPath: workspacePath)
                try? FileManager.default.moveItem(atPath: parked, toPath: workspacePath)
            }
        }
        try FileManager.default.moveItem(atPath: workspacePath, toPath: parked)
        try FileManager.default.createDirectory(
            atPath: workspacePath, withIntermediateDirectories: false)
        let attempt = supervisor.prepareIdentityLaunch(
            selection: selection,
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration())
        // The fake is not the boundary volume: refused, never stamped.
        guard case .failure(let error) = attempt else {
            Issue.record("pre-prepare swap must fail preparation")
            return
        }
        #expect(error == .preparationFailed(.workspaceInodeBoundaryFailed))
        try FileManager.default.removeItem(atPath: workspacePath)
        try FileManager.default.moveItem(atPath: parked, toPath: workspacePath)
        restored = true
        // Restored: preparation succeeds and the stamp is volume-anchored.
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection,
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        #expect(prepared.cwdIdentity.resolvedPath == prepared.resolvedWorkspacePath)
        let live = try #require(workspacePathIdentity(prepared.resolvedWorkspacePath))
        #expect(prepared.cwdIdentity.device == live.device)
        #expect(prepared.cwdIdentity.inode == live.inode)
        #expect(supervisor.cwdAnchoredToVolume(prepared.resolvedWorkspacePath))
    }

    @Test func redemptionUsesFrozenEnvironment() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(
            id: "redeem-env",
            target: "/bin/sh",
            projects: [tree.workspaceURL.path],
            environment: [RuntimeResourceProfile.Environment(
                name: "RV_REDEEM_PROBE", hostVariable: "RV_REDEEM_PROBE_HOST")])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: [
                "-c", "echo \"v=$RV_REDEEM_PROBE\" > env-probe.txt; exec /bin/sleep 30",
            ],
            io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration(),
            hostEnvironment: ["RV_REDEEM_PROBE_HOST": "FROZEN-A"]
        ).get()
        #expect(prepared.environment.entries.contains("RV_REDEEM_PROBE=FROZEN-A"))
        // Drift the live host environment after preparation.
        setenv("RV_REDEEM_PROBE_HOST", "LIVE-B", 1)
        defer { unsetenv("RV_REDEEM_PROBE_HOST") }
        let outcome = supervisor.redeemPreparedLaunch(
            commit: redeemCommit(prepared: prepared),
            sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-env.jsonl")),
            admission: .failClosed)
        guard case .launched(let runtime, _) = outcome else {
            Issue.record("expected launch, got \(outcome)")
            return
        }
        // The child observes the frozen value, never the drifted one.
        let probe = tree.workspaceURL.appendingPathComponent("env-probe.txt")
        let content = try #require(pollFile(at: probe, timeout: 10) {
            $0.hasSuffix("\n")
        })
        #expect(content == "v=FROZEN-A\n")
        try? supervisor.cancel(runtime).get()
    }

    @Test func redemptionPreservesArgvExactly() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let shDigest = try #require(RVFileDigest.sha256HexOfFile(atPath: "/bin/sh"))
        let selection = try AgentLaunchSelection.resolveCustom(
            executable: "/bin/sh",
            expectedContentDigestSHA256: shDigest).get()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection,
            arguments: [
                "-c", "printf '<%s>\\n' \"$@\" > argv-probe.txt; exec /bin/sleep 30", "argv0-probe",
                "alpha beta", "", "dup", "dup", "trailing ",
            ],
            io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let outcome = supervisor.redeemPreparedLaunch(
            commit: redeemCommit(prepared: prepared),
            sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-argv.jsonl")),
            admission: .failClosed)
        guard case .launched(let runtime, _) = outcome else {
            Issue.record("expected launch, got \(outcome)")
            return
        }
        // Order, duplicates, empty, and interior/trailing spaces preserved
        // byte-exact: no reparse, join, split, normalization, or sorting.
        let probe = tree.workspaceURL.appendingPathComponent("argv-probe.txt")
        let content = try #require(pollFile(at: probe, timeout: 10) {
            $0.components(separatedBy: "\n").count == 6
        })
        #expect(content == "<alpha beta>\n<>\n<dup>\n<dup>\n<trailing >\n")
        try? supervisor.cancel(runtime).get()
    }

    @Test func redeemedChildImageMatchesRetainedExecutable() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        guard case .launched(let runtime, _) = supervisor.redeemPreparedLaunch(
            commit: redeemCommit(prepared: prepared),
            sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-exe.jsonl")),
            admission: .failClosed)
        else {
            Issue.record("expected launch")
            return
        }
        let instance = try #require(supervisor.agentInstances.instance(forRuntime: runtime))
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(instance.groupLeader.pid, &buffer, UInt32(buffer.count))
        #expect(length > 0)
        #expect(String(cString: buffer) == "/bin/sleep")
        try supervisor.cancel(runtime).get()
    }

    @Test func bothAssuranceLevelsLaunchHonestly() throws {
        for assurance in [ExecutableAssurance.unattested, ExecutableAssurance.launchObserved] {
            let tree = try ContainmentTree()
            defer { tree.tearDown() }
            let supervisor = try redeemSupervisor(tree)
            defer { _ = supervisor.close() }
            let definition = redeemDefinition(
                projects: [tree.workspaceURL.path], assurance: assurance)
            let prepared = try supervisor.prepareIdentityLaunch(
                selection: redeemNamedSelection(definition),
                arguments: ["30"], io: .discard,
                host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
            ).get()
            guard case .launched(let runtime, _) = supervisor.redeemPreparedLaunch(
                commit: redeemCommit(prepared: prepared),
                sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-assurance.jsonl")),
                admission: .failClosed)
            else {
                Issue.record("expected launch for \(assurance)")
                continue
            }
            let live = try #require(supervisor.agentInstances.instance(forRuntime: runtime))
            // Redemption establishes exactly launchObserved: content and
            // signing unverified, honestly reported.
            #expect(live.assurance == .launchObserved)
            #expect(WorkspaceSessionSupervisor.redemptionAssuranceSatisfied(
                required: assurance))
            try supervisor.cancel(runtime).get()
        }
    }

    @Test func postSpawnFailureRecordsFailedWithoutRetry() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let commit = redeemCommit(prepared: prepared)
        let store = RuntimeSessionStore.file(
            tree.rootURL.appendingPathComponent("redeem-register.jsonl"))
        // The register fault fires after posix_spawn: the attempt is spent,
        // the child is retired, and the recorded outcome replays.
        let first = supervisor.redeemPreparedLaunch(
            commit: commit, sessionStore: store, admission: .failClosed,
            spawnFault: .register)
        #expect(redeemAccepted(first) == true)
        #expect(redeemFailedError(first) == .apply(.lifetimeBoundaryFailed))
        // Normal teardown: the announced instance is retired (no live
        // authority), no runtime survives, and the recorded outcome replays.
        let announced = supervisor.agentInstances.instances(inWorkspace: supervisor.id)
        #expect(announced.count == 1)
        for record in announced {
            #expect(supervisor.agentInstances.validity(of: record.id) == .inactive)
        }
        #expect(supervisor.runtimeFacts().isEmpty)
        let second = supervisor.redeemPreparedLaunch(
            commit: commit, sessionStore: store, admission: .failClosed,
            spawnFault: .register)
        #expect(second == first)
    }

    @Test func closeDuringRedemptionStaysSafe() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let commit = redeemCommit(prepared: prepared)
        let store = RuntimeSessionStore.file(
            tree.rootURL.appendingPathComponent("redeem-closerace.jsonl"))
        async let raced = supervisor.redeemPreparedLaunch(
            commit: commit, sessionStore: store, admission: .failClosed)
        _ = supervisor.close()
        let first = await raced
        // Whatever won, the safety property holds: at most one launch, and
        // the second attempt never creates a second runtime.
        let second = supervisor.redeemPreparedLaunch(
            commit: commit, sessionStore: store, admission: .failClosed)
        var ids = Set<RuntimeSessionID>()
        for outcome in [first, second] {
            if case .launched(let runtime, _) = outcome {
                ids.insert(runtime)
            }
        }
        #expect(ids.count <= 1)
        if case .launched(let firstRuntime, _) = first,
            case .launched(let secondRuntime, _) = second {
            #expect(firstRuntime == secondRuntime)
        }
    }

    @Test func launchGrantsNoTerminalOrDirectLaunchAuthority() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .pseudoTerminal(rows: 24, columns: 80),
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        guard case .launched(let runtime, _) = supervisor.redeemPreparedLaunch(
            commit: redeemCommit(prepared: prepared),
            sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-pty.jsonl")),
            admission: .failClosed)
        else {
            Issue.record("expected launch")
            return
        }
        // A launch permit authorizes only the initial IO mode. Terminal
        // input, resize, attach, and the direct identity-launch door stay
        // denied for every peer — before and after the launch alike. The
        // identity-launch ops exist as reserved cases, require a permit,
        // and never launch directly (see identityLaunchDoor below).
        #expect(WorkspaceControlOp(rawValue: "launchAgentRuntime") == .launchAgentRuntime)
        #expect(WorkspaceControlOp(rawValue: "launchCustomRuntime") == .launchCustomRuntime)
        for role in [nil] + TrustedRVComponentRole.allCases.map({ $0 as TrustedRVComponentRole? }) {
            let peer = PlatformPeerEvidence(
                processID: 1, effectiveUserID: 501, auditToken: nil,
                codeIdentity: PeerCodeIdentity(
                    identifier: "redeem-fixture", teamIdentifier: nil,
                    cdHash: Data([9]), executablePath: "/redeem-fixture",
                    isAdHoc: true, hardenedRuntime: true, injectionExceptions: []),
                componentRole: role)
            for operation: WorkspaceControlOp in [
                .launchAgentRuntime, .launchCustomRuntime, .launchRuntime,
                .ensureTerminalRuntime, .terminalInput, .acquireTerminalInput,
                .releaseTerminalInput, .resizeTerminal, .subscribeTerminal,
                .unsubscribeTerminal, .cancelRuntime, .closeWorkspace, .detach,
            ] {
                #expect(
                    WorkspaceOperationAuthorization.permits(operation, peer: peer) == false,
                    "denied: \(operation) for \(String(describing: role))")
            }
        }
        try supervisor.cancel(runtime).get()
    }

    @Test func identityLaunchDoorRequiresOperatorPermitAndNeverSpawns() throws {
        // The reserved identity-launch ops answer with the machine-readable
        // requiresOperatorPermit code instead of launching, even for a
        // fully valid request: no validation success can unlock a spawn.
        // Only the prepare→permit→redeem ceremony launches.
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let config = tree.rootURL.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let server = try WorkspaceHostServer.start(
            supervisor: supervisor,
            configurationDirectory: config,
            sessionStore: .file(tree.rootURL.appendingPathComponent("identity-door.jsonl")),
            admission: .failClosed
        ).get()
        defer { server.stop() }
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let requests = [
            WorkspaceControlRequest(
                operation: .launchAgentRuntime,
                id: UUID(),
                agentDefinitionID: definition.id.rawValue
            ),
            WorkspaceControlRequest(
                operation: .launchCustomRuntime,
                id: UUID(),
                executable: "/bin/sleep",
                customDefinitionDigest: String(repeating: "a", count: 64)
            ),
        ]
        for request in requests {
            let response = server.launchIdentity(request)
            #expect(response.ok == false)
            #expect(response.code == .requiresOperatorPermit)
            #expect(response.operation == request.operation)
        }
        #expect(supervisor.runtimeFacts().isEmpty)
    }

    @Test func redeemHandlerRefusesForeignIncarnation() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let host = WorkspaceHostID()
        let generation = WorkspaceHostGeneration()
        let definition = redeemDefinition(projects: [tree.workspaceURL.path])
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: redeemNamedSelection(definition),
            arguments: ["30"], io: .discard, host: host, generation: generation
        ).get()
        let commit = redeemCommit(prepared: prepared)
        func dto(
            hostID: UUID = host.rawValue,
            generation: UUID = generation.rawValue
        ) -> HostRedeemCommitDTO {
            HostRedeemCommitDTO(
                authorizationID: commit.authorizationID,
                workspaceSessionID: commit.workspace.rawValue,
                hostID: hostID, generation: generation,
                preparedID: commit.preparedID.rawValue,
                intentDigestHex: commit.intentDigest.sha256Hex,
                kind: "launchAgent",
                definitionID: definition.id.rawValue,
                revisionDigest: AgentDefinitionRevision.resolve(definition).digestHex)
        }
        let events = Mutex<[WorkspaceHostRedemptionAuditEvent]>([])
        let store = RuntimeSessionStore.file(
            tree.rootURL.appendingPathComponent("redeem-handler.jsonl"))
        // Wrong host, wrong generation: refused before any acceptance.
        for foreign in [dto(hostID: UUID()), dto(generation: UUID())] {
            let response = WorkspaceHostRedeemHandler.redeem(
                foreign, supervisor: supervisor, sessionStore: store,
                admission: .failClosed, host: host, generation: generation,
                audit: { event in events.withLock { $0.append(event) } })
            #expect(response.accepted == false)
            #expect(response.error == "unknown")
        }
        // The honest commit still launches through the handler.
        let launched = WorkspaceHostRedeemHandler.redeem(
            dto(), supervisor: supervisor, sessionStore: store,
            admission: .failClosed, host: host, generation: generation,
            audit: { event in events.withLock { $0.append(event) } })
        #expect(launched.accepted == true)
        guard let runtimeID = launched.runtimeSessionID else {
            Issue.record("expected runtime ID")
            return
        }
        let kinds = Set(events.withLock { $0.map(\.kind) })
        #expect(kinds.contains(.commitRefused))
        #expect(kinds.contains(.redemptionLaunched))
        try supervisor.cancel(RuntimeSessionID(rawValue: runtimeID)).get()
    }

    @Test func malformedCommitAuditsNoRawStrings() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try redeemSupervisor(tree)
        defer { _ = supervisor.close() }
        let host = WorkspaceHostID()
        let generation = WorkspaceHostGeneration()
        let planted = String(repeating: "x", count: 4_096)
        let malformed = HostRedeemCommitDTO(
            authorizationID: UUID(), workspaceSessionID: UUID(),
            hostID: host.rawValue, generation: generation.rawValue,
            preparedID: UUID(), intentDigestHex: planted, kind: planted,
            definitionID: nil, revisionDigest: nil)
        let events = Mutex<[WorkspaceHostRedemptionAuditEvent]>([])
        let response = WorkspaceHostRedeemHandler.redeem(
            malformed, supervisor: supervisor,
            sessionStore: .file(tree.rootURL.appendingPathComponent("redeem-malformed.jsonl")),
            admission: .failClosed, host: host, generation: generation,
            audit: { event in events.withLock { $0.append(event) } })
        #expect(response.accepted == false)
        #expect(response.error == "unknown")
        let recorded = try #require(events.withLock { $0.first })
        #expect(recorded.kind == .commitRefused)
        #expect(recorded.intentDigestHex.isEmpty)
        #expect(recorded.operationKind == "malformed")
    }
}

/// Polls a workspace file until `until` accepts its UTF-8 content or the
/// deadline passes. Output observation only; never a fence.
private func pollFile(
    at url: URL,
    timeout: TimeInterval,
    until: (String) -> Bool
) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let data = try? Data(contentsOf: url),
            !data.isEmpty,
            let text = String(data: data, encoding: .utf8),
            until(text) {
            return text
        }
        usleep(20_000)
    }
    if let data = try? Data(contentsOf: url),
        let text = String(data: data, encoding: .utf8),
        until(text) {
        return text
    }
    return nil
}
#endif
