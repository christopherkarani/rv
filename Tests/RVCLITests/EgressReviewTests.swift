import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

private func egressCLITempConfig() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-egress-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func egressCLIProposal(
    store: PendingApprovalStore,
    host: String = "api.example.com",
    port: Int = 443,
    now: Date = Date()
) async throws -> PendingApproval {
    let rule = try #require(LiveNetworkRule(host: host, port: port))
    let directory = try #require(WorkingDirectory(validating: "/tmp/rv-egress-cli"))
    let request = try #require(
        EgressProposal.request(
            id: PendingApprovalStore.makeID(),
            rule: rule,
            workspaceSession: WorkspaceSessionID(),
            workspaceDirectory: directory
        )
    )
    return try await store.create(request, now: now)
}

struct EgressReviewTests {
    @Test func pendingListsNetworkProposalsOldestFirst() async throws {
        let store = PendingApprovalStore(baseDirectory: try egressCLITempConfig())
        let first = try await egressCLIProposal(store: store, host: "a.example.com")
        let second = try await egressCLIProposal(
            store: store, host: "b.example.com",
            now: Date().addingTimeInterval(5))
        let views = try await EgressReviewRun.pending(store: store, now: Date())
        #expect(views.map(\.id) == [first.id.rawValue, second.id.rawValue])
        #expect(views.first?.host == "a.example.com")
        #expect(views.first?.port == 443)
        #expect(views.first?.state == "awaiting-human")
        #expect(views.first?.reason == "mandatoryHuman")
    }

    @Test func stateTextCoversLifecycle() {
        #expect(EgressReviewRun.stateText(.awaitingHuman) == "awaiting-human")
        #expect(
            EgressReviewRun.stateText(
                .resolved(ApprovalResolution(decision: .allowOnce, resolvedAt: Date())))
                == "resolved-allowOnce")
        #expect(
            EgressReviewRun.stateText(
                .consumed(
                    ApprovalResolution(decision: .deny, resolvedAt: Date()), at: Date()))
                == "consumed-deny")
        #expect(EgressReviewRun.stateText(.expired(at: Date())) == "expired")
        #expect(EgressReviewRun.stateText(.canceled(at: Date())) == "canceled")
        #expect(
            EgressReviewRun.stateText(
                .timedOut(ApprovalTimeoutEnding(policy: .autoDeny, at: Date())))
                == "timed-out-autoDeny")
    }

    @Test func prettyPendingMentionsHostPort() async throws {
        #expect(
            EgressReviewRun.prettyPending([])
                == "No pending network proposals.\nloaded: unknown (supervisor has not reported)\n"
        )
        let store = PendingApprovalStore(baseDirectory: try egressCLITempConfig())
        _ = try await egressCLIProposal(store: store, host: "a.example.com", port: 8443)
        let views = try await EgressReviewRun.pending(store: store, now: Date())
        let text = EgressReviewRun.prettyPending(views)
        #expect(text.contains("a.example.com:8443"))
        #expect(text.contains("awaiting-human"))
    }

    @Test func robotRoundTrips() async throws {
        let store = PendingApprovalStore(baseDirectory: try egressCLITempConfig())
        _ = try await egressCLIProposal(store: store)
        let views = try await EgressReviewRun.pending(store: store, now: Date())
        let encoded = try EgressReviewRun.robot(views)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            [EgressProposalView].self, from: Data(encoded.utf8))
        #expect(decoded == views)
    }

    @Test func showIncludesRejectionReason() async throws {
        let store = PendingApprovalStore(baseDirectory: try egressCLITempConfig())
        let created = try await egressCLIProposal(store: store)
        let now = Date()
        let resolved = try await store.resolveWithReason(
            id: created.id,
            decision: .deny,
            fingerprint: created.fingerprint,
            identity: created.identity,
            reason: "tracker domain",
            now: now
        )
        let view = try #require(EgressReviewRun.view(for: resolved))
        #expect(view.state == "resolved-deny")
        let text = EgressReviewRun.prettyShow(
            view, rejectionReason: await store.rejectionReason(for: created.id))
        #expect(text.contains("tracker domain"))
        let robot = try EgressReviewRun.robotShow(
            view, rejectionReason: await store.rejectionReason(for: created.id))
        #expect(robot.contains("tracker domain"))
    }

    @Test func denialsLogParsesAndDropsCorruptLines() {
        let text = """
        {"host":"a.example.com","port":"443","reason":"denied-policy","recordedAt":"1720000000.0"}
        not json
        {"host":"b.example.com","port":"oops","reason":"denied-policy","recordedAt":"1720000000.0"}
        {"host":"c.example.com","port":"80","reason":"dns-failed","recordedAt":"1720000001.5"}

        """
        let views = EgressReviewRun.parseDenialsLog(text)
        #expect(views.count == 2)
        #expect(views.first?.host == "a.example.com")
        #expect(views.first?.reason == "denied-policy")
        #expect(views.last?.port == 80)
        #expect(EgressReviewRun.prettyDenials(views).contains("a.example.com:443"))
        #expect(EgressReviewRun.prettyDenials([]) == "No recorded egress denials.\n")
    }

    @Test func reviewUnchangedDetectsDrift() async throws {
        let store = PendingApprovalStore(baseDirectory: try egressCLITempConfig())
        let created = try await egressCLIProposal(store: store)
        #expect(EgressReviewRun.reviewUnchanged(before: created, after: created))
        var swappedFingerprint = created
        swappedFingerprint.action = .shell(
            .effectOnly(
                EffectShell(
                    fingerprint: ActionFingerprint(rawValue: "egress:evil.example.com:443"),
                    scope: created.action.scope
                )
            )
        )
        #expect(
            EgressReviewRun.reviewUnchanged(before: created, after: swappedFingerprint) == false)
        var resolved = created
        resolved.state = .resolved(
            ApprovalResolution(decision: .allowOnce, resolvedAt: Date()))
        #expect(EgressReviewRun.reviewUnchanged(before: created, after: resolved) == false)
    }

    @Test func ceremonyReasonsNameTheGrant() {
        #expect(
            EgressReviewRun.approveReason(host: "a.example.com", port: 443)
                == "Allow network egress to a.example.com:443.")
        #expect(
            EgressReviewRun.denyReason(host: "a.example.com", port: 443)
                == "Deny network egress to a.example.com:443.")
    }

    @Test func approveCeremonyResolvesAllowOnce() async throws {
        // The production verb stays boundary-refused, but the ceremony
        // itself must execute somewhere: dark security code would meet
        // its latent bugs for the first time in production.
        let store = PendingApprovalStore(baseDirectory: try egressCLITempConfig())
        let created = try await egressCLIProposal(store: store)
        let now = Date()
        let view = try await withCLIProcess(ownerAuthOutcome: .authenticated) {
            try await EgressReviewRun.approve(
                id: created.id,
                tty: TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false),
                robot: false,
                store: store,
                now: now,
                refreshedNow: { now }
            )
        }
        // The returned view reflects the resolved row, not the pre-auth one.
        #expect(view.state == "resolved-allowOnce")
        let loaded = try await store.load(id: created.id, now: now)
        guard case .resolved(let resolution) = loaded.state else {
            Issue.record("expected resolved state, got \(loaded.state)")
            return
        }
        #expect(resolution.decision == .allowOnce)
    }

    @Test func denyCeremonyPersistsCanonicalReason() async throws {
        let store = PendingApprovalStore(baseDirectory: try egressCLITempConfig())
        let created = try await egressCLIProposal(store: store)
        let now = Date()
        let view = try await withCLIProcess(ownerAuthOutcome: .authenticated) {
            try await EgressReviewRun.deny(
                id: created.id,
                reason: "  Tracker Domain  ",
                tty: TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false),
                robot: false,
                store: store,
                now: now,
                refreshedNow: { now }
            )
        }
        #expect(view.state == "resolved-deny")
        // Canonical form is the trimmed text (control scalars refused).
        #expect(await store.rejectionReason(for: created.id) == "Tracker Domain")
    }

    @Test func approveCeremonyFailsClosedWhenRobotOrNotTTY() async throws {
        let store = PendingApprovalStore(baseDirectory: try egressCLITempConfig())
        let created = try await egressCLIProposal(store: store)
        await #expect(throws: AllowOnceError.robotRefused) {
            try await withCLIProcess(ownerAuthOutcome: .authenticated) {
                try await EgressReviewRun.approve(
                    id: created.id,
                    tty: TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false),
                    robot: true,
                    store: store,
                    now: Date()
                )
            }
        }
        await #expect(throws: AllowOnceError.ttyRequired) {
            try await withCLIProcess(ownerAuthOutcome: .authenticated) {
                try await EgressReviewRun.approve(
                    id: created.id,
                    tty: TTYCapability(stdinIsTTY: false, stdoutIsTTY: true, ci: false),
                    robot: false,
                    store: store,
                    now: Date()
                )
            }
        }
        // Nothing resolved behind the refusals.
        let loaded = try await store.load(id: created.id, now: Date())
        guard case .awaitingHuman = loaded.state else {
            Issue.record("expected awaitingHuman, got \(loaded.state)")
            return
        }
    }

    @Test func approveCeremonyReportsProposalChangedWhenResolvedUnderneath() async throws {
        let store = PendingApprovalStore(baseDirectory: try egressCLITempConfig())
        let created = try await egressCLIProposal(store: store)
        let now = Date()
        _ = try await store.resolve(
            id: created.id,
            decision: .deny,
            fingerprint: created.fingerprint,
            identity: created.identity,
            now: now
        )
        await #expect(throws: EgressReviewError.notAwaiting("resolved-deny")) {
            try await withCLIProcess(ownerAuthOutcome: .authenticated) {
                try await EgressReviewRun.approve(
                    id: created.id,
                    tty: TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false),
                    robot: false,
                    store: store,
                    now: now,
                    refreshedNow: { now }
                )
            }
        }
    }

    @Test func approveIsBoundaryRefused() async throws {
        let command = try EgressApprove.parse(["some-id"])
        await #expect(throws: ValidationError.self) {
            try await command.run()
        }
    }

    @Test func denyIsBoundaryRefused() async throws {
        let command = try EgressDeny.parse(["some-id", "--reason", "nope"])
        await #expect(throws: ValidationError.self) {
            try await command.run()
        }
    }

    @Test func loadedSnapshotParsesValidFile() throws {
        let config = try egressCLITempConfig()
        let rule = try #require(LiveNetworkRule(host: "api.example.com", port: 443))
        let snapshot = EgressLoadedSnapshot(
            generation: 7, rules: [rule], approvalIDs: ["abc123"],
            updatedAt: Date(timeIntervalSince1970: 1_000_000))
        let data = try JSONEncoder().encode(snapshot)
        try data.write(
            to: RVPolicyPaths.egressLoadedSnapshotFile(inConfigDir: config), options: .atomic)
        let parsed = try #require(EgressReviewRun.loadedSnapshot(configDirectory: config))
        #expect(parsed.generation == 7)
        #expect(parsed.rules == [rule])
        #expect(parsed.approvalIDs == ["abc123"])
    }

    @Test func loadedSnapshotNilWhenMissingOrCorrupt() throws {
        let config = try egressCLITempConfig()
        #expect(EgressReviewRun.loadedSnapshot(configDirectory: config) == nil)
        let url = RVPolicyPaths.egressLoadedSnapshotFile(inConfigDir: config)
        try Data("not json".utf8).write(to: url, options: .atomic)
        #expect(EgressReviewRun.loadedSnapshot(configDirectory: config) == nil)
        try Data("{\"schemaVersion\":999}".utf8).write(to: url, options: .atomic)
        #expect(EgressReviewRun.loadedSnapshot(configDirectory: config) == nil)
    }

    @Test func prettyPendingShowsLoadedFooter() throws {
        let rule = try #require(LiveNetworkRule(host: "api.example.com", port: 443))
        let snapshot = EgressLoadedSnapshot(
            generation: 7, rules: [rule], approvalIDs: ["a", "b"],
            updatedAt: Date(timeIntervalSince1970: 1_000_000))
        let withLoaded = EgressReviewRun.prettyPending([], loaded: snapshot)
        #expect(withLoaded.contains("generation 7"))
        #expect(withLoaded.contains("1 rule"))
        let withoutLoaded = EgressReviewRun.prettyPending([], loaded: nil)
        #expect(withoutLoaded.contains("unknown"))
    }

    @Test func prettyShowMarksLoadedRule() throws {
        let view = EgressProposalView(
            id: "abc123", host: "api.example.com", port: 443, state: "resolved-allowOnce",
            reason: "mandatoryHuman", createdAt: Date(), expiresAt: Date())
        let rule = try #require(LiveNetworkRule(host: "api.example.com", port: 443))
        let other = try #require(LiveNetworkRule(host: "other.example.com", port: 443))
        let loaded = EgressLoadedSnapshot(
            generation: 7, rules: [rule], approvalIDs: ["abc123"], updatedAt: Date())
        #expect(EgressReviewRun.prettyShow(view, rejectionReason: nil, loaded: loaded)
            .contains("loaded yes"))
        let missing = EgressLoadedSnapshot(
            generation: 7, rules: [other], approvalIDs: [], updatedAt: Date())
        #expect(EgressReviewRun.prettyShow(view, rejectionReason: nil, loaded: missing)
            .contains("loaded no"))
        #expect(EgressReviewRun.prettyShow(view, rejectionReason: nil, loaded: nil)
            .contains("loaded unknown"))
    }

    @Test func robotShowCarriesLoadedBlock() throws {
        let view = EgressProposalView(
            id: "abc123", host: "api.example.com", port: 443, state: "resolved-allowOnce",
            reason: "mandatoryHuman", createdAt: Date(), expiresAt: Date())
        let rule = try #require(LiveNetworkRule(host: "api.example.com", port: 443))
        let loaded = EgressLoadedSnapshot(
            generation: 7, rules: [rule], approvalIDs: ["abc123"], updatedAt: Date())
        let text = try EgressReviewRun.robotShow(view, rejectionReason: nil, loaded: loaded)
        #expect(text.contains("\"generation\":7"))
        #expect(text.contains("\"ruleLoaded\":true"))
        let plain = try EgressReviewRun.robotShow(view, rejectionReason: nil, loaded: nil)
        #expect(plain.contains("\"loaded\"") == false)
    }
}
