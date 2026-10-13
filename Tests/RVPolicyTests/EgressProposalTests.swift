import Foundation
import Testing
import RVDomain
@testable import RVPolicy

private func egressTempConfig(named: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-egress-\(named)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func egressWorkspace() throws -> (WorkspaceSessionID, WorkingDirectory) {
    let id = WorkspaceSessionID()
    let directory = try #require(WorkingDirectory(validating: "/tmp/rv-egress-ws"))
    return (id, directory)
}

struct EgressProposalTests {
    @Test func liveRuleCanonicalizesHost() {
        let rule = LiveNetworkRule(host: "API.Example.COM.", port: 443)
        #expect(rule?.host == "api.example.com")
        #expect(rule?.port == 443)
    }

    @Test func liveRuleRejectsNonNetwork() {
        #expect(LiveNetworkRule(host: "../etc/passwd", port: 443) == nil)
        #expect(LiveNetworkRule(host: "/etc/passwd", port: 443) == nil)
        #expect(LiveNetworkRule(host: "a/b", port: 443) == nil)
        #expect(LiveNetworkRule(host: "localhost", port: 443) == nil)
        #expect(LiveNetworkRule(host: "", port: 443) == nil)
        #expect(LiveNetworkRule(host: "127.0.0.1", port: 443) == nil)
        #expect(LiveNetworkRule(host: "10.0.0.1", port: 443) == nil)
        #expect(LiveNetworkRule(host: "-bad.example", port: 443) == nil)
        #expect(LiveNetworkRule(host: "bad-.example", port: 443) == nil)
        #expect(LiveNetworkRule(host: "0x7f.example", port: 443) == nil)
        #expect(LiveNetworkRule(host: "api.example.com", port: 0) == nil)
        #expect(LiveNetworkRule(host: "api.example.com", port: 65536) == nil)
        #expect(LiveNetworkRule(host: "api.example.com", port: -1) == nil)
        let overlong = String(repeating: "a", count: 64) + ".example.com"
        #expect(LiveNetworkRule(host: overlong, port: 443) == nil)
    }

    @Test func fingerprintRoundTrips() {
        let rule = LiveNetworkRule(host: "api.example.com", port: 8443)!
        let fingerprint = EgressProposal.fingerprint(for: rule)
        #expect(fingerprint.rawValue == "egress:api.example.com:8443")
        #expect(EgressProposal.parse(fingerprint) == rule)
    }

    @Test func parseRejectsDrift() {
        #expect(EgressProposal.parse(ActionFingerprint(rawValue: "egress:api.example.com")) == nil)
        #expect(EgressProposal.parse(ActionFingerprint(rawValue: "egress::443")) == nil)
        #expect(EgressProposal.parse(ActionFingerprint(rawValue: "egress:api.example.com:notaport")) == nil)
        #expect(EgressProposal.parse(ActionFingerprint(rawValue: "egress:127.0.0.1:443")) == nil)
        #expect(EgressProposal.parse(ActionFingerprint(rawValue: "EGRESS:api.example.com:443")) == nil)
        #expect(EgressProposal.parse(ActionFingerprint(rawValue: "file:grok:s:c:read:/x")) == nil)
        #expect(EgressProposal.parse(ActionFingerprint(rawValue: "")) == nil)
    }

    @Test func requestIsHumanByDefault() throws {
        let (id, directory) = try egressWorkspace()
        let rule = LiveNetworkRule(host: "api.example.com", port: 443)!
        let request = try #require(
            EgressProposal.request(
                id: ApprovalID(rawValue: "test-id"),
                rule: rule,
                workspaceSession: id,
                workspaceDirectory: directory
            )
        )
        #expect(request.reason == .mandatoryHuman)
        #expect(request.timeoutPolicy == .autoDeny)
        #expect(request.continuation == .retry(EgressProposal.fingerprint(for: rule)))
        #expect(request.identity.session.rawValue.hasPrefix("egress:"))
        #expect(request.identity.session.rawValue.contains(id.rawValue.uuidString.lowercased()))
        guard case .shell(.effectOnly(let shell)) = request.action else {
            Issue.record("network proposal must be effect-only")
            return
        }
        #expect(shell.supportingCommand == nil)
        #expect(shell.scope.workingDirectory == directory)
    }

    @Test func channelIsAdditiveAndCapped() {
        let channel = NetworkRuleLiveChannel()
        #expect(channel.currentGeneration == 0)
        let first = LiveNetworkRule(host: "a.example.com", port: 443)!
        let second = LiveNetworkRule(host: "b.example.com", port: 443)!
        guard case .appended(let gen1) = channel.append(first) else {
            Issue.record("first append must apply")
            return
        }
        #expect(gen1 == 1)
        guard case .duplicate(let genDup) = channel.append(first) else {
            Issue.record("duplicate must not bump generation")
            return
        }
        #expect(genDup == 1)
        guard case .appended(let gen2) = channel.append(second) else {
            Issue.record("second append must apply")
            return
        }
        #expect(gen2 == 2)
        #expect(channel.contains(first))
        #expect(channel.snapshot().rules.count == 2)
    }

    @Test func channelRefusesPastCap() {
        let channel = NetworkRuleLiveChannel()
        for index in 0..<NetworkRuleLiveChannel.maxRules {
            let rule = LiveNetworkRule(host: "h\(index).example.com", port: 443)!
            guard case .appended = channel.append(rule) else {
                Issue.record("append \(index) must apply")
                return
            }
        }
        let extra = LiveNetworkRule(host: "overflow.example.com", port: 443)!
        guard case .refusedFull(let generation) = channel.append(extra) else {
            Issue.record("append past cap must refuse")
            return
        }
        #expect(generation == UInt64(NetworkRuleLiveChannel.maxRules))
        #expect(channel.contains(extra) == false)
    }

    @Test func rejectionReasonRoundTrips() async throws {
        let config = try egressTempConfig(named: "reason")
        let store = PendingApprovalStore(baseDirectory: config)
        let (id, directory) = try egressWorkspace()
        let rule = LiveNetworkRule(host: "api.example.com", port: 443)!
        let request = try #require(
            EgressProposal.request(
                id: PendingApprovalStore.makeID(),
                rule: rule,
                workspaceSession: id,
                workspaceDirectory: directory
            )
        )
        let now = Date()
        let created = try await store.create(request, now: now)
        let resolved = try await store.resolveWithReason(
            id: created.id,
            decision: .deny,
            fingerprint: created.fingerprint,
            identity: created.identity,
            reason: "  exfil risk  ",
            now: now
        )
        guard case .resolved(let resolution) = resolved.state else {
            Issue.record("deny must resolve")
            return
        }
        #expect(resolution.decision == .deny)
        #expect(await store.rejectionReason(for: created.id) == "exfil risk")
        #expect(await store.rejectionReason(for: ApprovalID(rawValue: "missing")) == nil)
    }

    @Test func denyRequiresReason() async throws {
        let config = try egressTempConfig(named: "reason-required")
        let store = PendingApprovalStore(baseDirectory: config)
        let (id, directory) = try egressWorkspace()
        let rule = LiveNetworkRule(host: "api.example.com", port: 443)!
        for bad in [nil, "", "   ", "line one\nline two", String(repeating: "x", count: 501)] {
            let request = try #require(
                EgressProposal.request(
                    id: PendingApprovalStore.makeID(),
                    rule: rule,
                    workspaceSession: id,
                    workspaceDirectory: directory
                )
            )
            let now = Date()
            let created = try await store.create(request, now: now)
            await #expect(throws: PendingApprovalError.invalidRequest) {
                try await store.resolveWithReason(
                    id: created.id,
                    decision: .deny,
                    fingerprint: created.fingerprint,
                    identity: created.identity,
                    reason: bad,
                    now: now
                )
            }
            let reloaded = try await store.load(id: created.id, now: now)
            guard case .awaitingHuman = reloaded.state else {
                Issue.record("failed deny must leave the row awaiting")
                return
            }
        }
    }

    @Test func approvalCarriesNoReason() async throws {
        let config = try egressTempConfig(named: "approve-no-reason")
        let store = PendingApprovalStore(baseDirectory: config)
        let (id, directory) = try egressWorkspace()
        let rule = LiveNetworkRule(host: "api.example.com", port: 443)!
        let request = try #require(
            EgressProposal.request(
                id: PendingApprovalStore.makeID(),
                rule: rule,
                workspaceSession: id,
                workspaceDirectory: directory
            )
        )
        let now = Date()
        let created = try await store.create(request, now: now)
        await #expect(throws: PendingApprovalError.invalidRequest) {
            try await store.resolveWithReason(
                id: created.id,
                decision: .allowOnce,
                fingerprint: created.fingerprint,
                identity: created.identity,
                reason: "looks fine",
                now: now
            )
        }
        let resolved = try await store.resolveWithReason(
            id: created.id,
            decision: .allowOnce,
            fingerprint: created.fingerprint,
            identity: created.identity,
            reason: nil,
            now: now
        )
        guard case .resolved = resolved.state else {
            Issue.record("approval must resolve")
            return
        }
        #expect(await store.rejectionReason(for: created.id) == nil)
    }

    @Test func networkProposalFilter() async throws {
        let config = try egressTempConfig(named: "filter")
        let store = PendingApprovalStore(baseDirectory: config)
        let (id, directory) = try egressWorkspace()
        let rule = LiveNetworkRule(host: "api.example.com", port: 443)!
        let request = try #require(
            EgressProposal.request(
                id: PendingApprovalStore.makeID(),
                rule: rule,
                workspaceSession: id,
                workspaceDirectory: directory
            )
        )
        let now = Date()
        let created = try await store.create(request, now: now)
        #expect(EgressProposal.isNetworkProposal(created))
        #expect(EgressProposal.rule(for: created) == rule)
        let shellFingerprint = ActionFingerprint.make(
            host: .grok,
            session: SessionID(validating: "s"),
            cwd: directory,
            command: ShellCommand(rawValue: "ls")
        )
        let shellRequest = PendingApprovalRequest(
            id: PendingApprovalStore.makeID(),
            identity: ApprovalIdentity(
                session: try #require(SessionID(validating: "s")),
                agent: .grok
            ),
            action: .shell(
                .effectOnly(
                    EffectShell(
                        fingerprint: shellFingerprint,
                        scope: ActionScope(workingDirectory: directory)
                    )
                )
            ),
            reason: .hostAsk,
            continuation: .retry(shellFingerprint),
            timeoutPolicy: .autoDeny
        )
        let shellRow = try await store.create(shellRequest, now: now)
        #expect(EgressProposal.isNetworkProposal(shellRow) == false)
        #expect(EgressProposal.rule(for: shellRow) == nil)
    }
}
