import Foundation
import Testing
import RVDomain
@testable import RVPolicy

private func reviewTokenConfig() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-egress-review-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let reviewNow = Date(timeIntervalSince1970: 1_800_000_000)

private func propose(
    _ store: PendingApprovalStore,
    host: String,
    port: Int = 443,
    workspace: WorkspaceSessionID
) async throws -> PendingApproval {
    let rule = try #require(LiveNetworkRule(host: host, port: port))
    let directory = try #require(WorkingDirectory(validating: "/tmp/rv-egress-review"))
    let request = try #require(
        EgressProposal.request(
            id: PendingApprovalStore.makeID(),
            rule: rule,
            workspaceSession: workspace,
            workspaceDirectory: directory
        )
    )
    return try await store.create(request, now: reviewNow)
}

private func grant(_ store: PendingApprovalStore, _ record: PendingApproval) async throws {
    _ = try await store.resolve(
        id: record.id, decision: .allowOnce,
        fingerprint: record.fingerprint, identity: record.identity, now: reviewNow
    )
}

private func token(_ store: PendingApprovalStore, _ record: PendingApproval) async throws -> EgressReviewToken {
    try #require(EgressReview.token(for: record.id, in: try await store.records(now: reviewNow)))
}

private func approveReviewed(
    _ store: PendingApprovalStore, _ record: PendingApproval, _ reviewed: EgressReviewToken
) async throws -> PendingApproval? {
    try await store.resolve(
        id: record.id, decision: .allowOnce,
        fingerprint: record.fingerprint, identity: record.identity, now: reviewNow,
        onlyIf: { EgressReview.token(for: record.id, in: $0) == reviewed }
    )
}

private func isAwaiting(_ store: PendingApprovalStore, _ record: PendingApproval) async throws -> Bool {
    if case .awaitingHuman = try await store.load(id: record.id, now: reviewNow).state { return true }
    return false
}

/// The review token binds an owner's egress approval to the proposal as
/// shown plus the workspace's live grant state; a move between showing
/// and applying refuses the approval.
struct EgressReviewTokenTests {
    @Test func approvalSucceedsWhenNothingChanged() async throws {
        let store = PendingApprovalStore(baseDirectory: try reviewTokenConfig())
        let workspace = WorkspaceSessionID()
        let proposal = try await propose(store, host: "api.example.com", workspace: workspace)
        let reviewed = try await token(store, proposal)
        #expect(try await token(store, proposal) == reviewed)
        let resolved = try #require(try await approveReviewed(store, proposal, reviewed))
        guard case .resolved(let resolution) = resolved.state else {
            Issue.record("expected resolved, got \(resolved.state)")
            return
        }
        #expect(resolution.decision == .allowOnce)
    }

    /// rv has no saved egress policy file: the static policy is compiled
    /// in, so the workspace's durable egress policy is its grant set. A
    /// grant for another host landing between review and apply is the
    /// policy save the owner did not see.
    @Test func approvalRefusedAfterWorkspacePolicyChangedInBetween() async throws {
        let store = PendingApprovalStore(baseDirectory: try reviewTokenConfig())
        let workspace = WorkspaceSessionID()
        let proposal = try await propose(store, host: "api.example.com", workspace: workspace)
        let other = try await propose(store, host: "cdn.example.net", workspace: workspace)
        let reviewed = try await token(store, proposal)
        try await grant(store, other)
        #expect(try await token(store, proposal) != reviewed)
        #expect(try await approveReviewed(store, proposal, reviewed) == nil)
        #expect(try await isAwaiting(store, proposal))
    }

    @Test func approvalRefusedAfterSameHostGrantLandsInBetween() async throws {
        let store = PendingApprovalStore(baseDirectory: try reviewTokenConfig())
        let workspace = WorkspaceSessionID()
        let proposal = try await propose(store, host: "api.example.com", workspace: workspace)
        let sameHost = try await propose(store, host: "api.example.com", port: 80, workspace: workspace)
        let reviewed = try await token(store, proposal)
        try await grant(store, sameHost)
        #expect(try await approveReviewed(store, proposal, reviewed) == nil)
        #expect(try await isAwaiting(store, proposal))
        // Reviewing again against the new state succeeds.
        let fresh = try await token(store, proposal)
        #expect(try await approveReviewed(store, proposal, fresh) != nil)
    }

    /// Grants in another workspace and denials change no effective grant
    /// for this workspace, so they do not invalidate the review.
    @Test func unrelatedDecisionsKeepTheReview() async throws {
        let store = PendingApprovalStore(baseDirectory: try reviewTokenConfig())
        let workspace = WorkspaceSessionID()
        let proposal = try await propose(store, host: "api.example.com", workspace: workspace)
        let elsewhere = try await propose(store, host: "api.example.com", port: 80, workspace: WorkspaceSessionID())
        let denied = try await propose(store, host: "cdn.example.net", workspace: workspace)
        let reviewed = try await token(store, proposal)
        try await grant(store, elsewhere)
        _ = try await store.resolve(
            id: denied.id, decision: .deny,
            fingerprint: denied.fingerprint, identity: denied.identity, now: reviewNow
        )
        #expect(try await approveReviewed(store, proposal, reviewed) != nil)
    }

    @Test func tokenFromOtherDisplayedDataIsRefused() async throws {
        let store = PendingApprovalStore(baseDirectory: try reviewTokenConfig())
        let workspace = WorkspaceSessionID()
        let proposal = try await propose(store, host: "api.example.com", workspace: workspace)
        let other = try await propose(store, host: "api.example.org", workspace: workspace)
        let otherToken = try await token(store, other)
        #expect(otherToken != (try await token(store, proposal)))
        #expect(try await approveReviewed(store, proposal, otherToken) == nil)
        #expect(try await approveReviewed(store, proposal, EgressReviewToken(rawValue: "")) == nil)
        #expect(try await isAwaiting(store, proposal))
    }

    // The ledger's refusals run before the token compare, so each keeps
    // its own error instead of reading as a review change.

    @Test func boundResolveOfAResolvedRowIsAlreadyResolved() async throws {
        let store = PendingApprovalStore(baseDirectory: try reviewTokenConfig())
        let proposal = try await propose(store, host: "api.example.com", workspace: WorkspaceSessionID())
        let reviewed = try await token(store, proposal)
        try await grant(store, proposal)
        await #expect(throws: PendingApprovalError.alreadyResolved) {
            _ = try await approveReviewed(store, proposal, reviewed)
        }
    }

    @Test func boundResolveOfAnUnknownRowIsNotFound() async throws {
        let store = PendingApprovalStore(baseDirectory: try reviewTokenConfig())
        let proposal = try await propose(store, host: "api.example.com", workspace: WorkspaceSessionID())
        let reviewed = try await token(store, proposal)
        let otherStore = PendingApprovalStore(baseDirectory: try reviewTokenConfig())
        await #expect(throws: PendingApprovalError.notFound) {
            _ = try await approveReviewed(otherStore, proposal, reviewed)
        }
    }

    @Test func boundResolveOfAnExpiredRowIsTimedOut() async throws {
        let store = PendingApprovalStore(baseDirectory: try reviewTokenConfig())
        let proposal = try await propose(store, host: "api.example.com", workspace: WorkspaceSessionID())
        let reviewed = try await token(store, proposal)
        let later = proposal.expiresAt.addingTimeInterval(1)
        await #expect(throws: PendingApprovalError.timedOut) {
            _ = try await store.resolve(
                id: proposal.id, decision: .allowOnce,
                fingerprint: proposal.fingerprint, identity: proposal.identity, now: later,
                onlyIf: { EgressReview.token(for: proposal.id, in: $0) == reviewed }
            )
        }
    }

    /// An unreadable ledger is a store failure, never an empty ledger.
    @Test func boundResolveOfAnUnreadableStoreFailsClosed() async throws {
        guard geteuid() != 0 else { return }  // root reads through 0o000
        let config = try reviewTokenConfig()
        let store = PendingApprovalStore(baseDirectory: config)
        let proposal = try await propose(store, host: "api.example.com", workspace: WorkspaceSessionID())
        let reviewed = try await token(store, proposal)
        let file = RVPolicyPaths.pendingApprovalsFile(inConfigDir: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        await #expect(throws: PendingApprovalError.encodeFailed) {
            _ = try await approveReviewed(store, proposal, reviewed)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try await isAwaiting(store, proposal))
    }

    @Test func noTokenForRowsThatCannotBeApproved() async throws {
        let store = PendingApprovalStore(baseDirectory: try reviewTokenConfig())
        let proposal = try await propose(store, host: "api.example.com", workspace: WorkspaceSessionID())
        try await grant(store, proposal)
        let records = try await store.records(now: reviewNow)
        #expect(EgressReview.token(for: proposal.id, in: records) == nil)
        #expect(EgressReview.token(for: ApprovalID(rawValue: "missing"), in: records) == nil)
    }

    @Test func grantsListAuthorizingRulesForOneWorkspace() async throws {
        let store = PendingApprovalStore(baseDirectory: try reviewTokenConfig())
        let workspace = WorkspaceSessionID()
        let first = try await propose(store, host: "b.example.com", workspace: workspace)
        let second = try await propose(store, host: "a.example.com", port: 8443, workspace: workspace)
        let waiting = try await propose(store, host: "c.example.com", workspace: workspace)
        try await grant(store, first)
        try await grant(store, second)
        let records = try await store.records(now: reviewNow)
        #expect(
            EgressReview.grants(for: waiting.identity, in: records)
                == [LiveNetworkRule(host: "a.example.com", port: 8443)!, LiveNetworkRule(host: "b.example.com", port: 443)!]
        )
    }
}
