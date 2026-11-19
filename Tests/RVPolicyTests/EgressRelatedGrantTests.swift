import Foundation
import Testing
import RVDomain
@testable import RVPolicy

private func relatedConfig() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-egress-related-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let relatedNow = Date(timeIntervalSince1970: 1_800_000_000)

private func propose(
    _ store: PendingApprovalStore,
    host: String = "api.example.com",
    port: Int = 443,
    workspace: WorkspaceSessionID
) async throws -> PendingApproval {
    let rule = try #require(LiveNetworkRule(host: host, port: port))
    let directory = try #require(WorkingDirectory(validating: "/tmp/rv-egress-related"))
    let request = try #require(
        EgressProposal.request(
            id: PendingApprovalStore.makeID(),
            rule: rule,
            workspaceSession: workspace,
            workspaceDirectory: directory
        )
    )
    return try await store.create(request, now: relatedNow)
}

/// The owner's approve path: bound to the review token of the snapshot
/// the owner saw, checked under the store lock.
private func approveReviewed(_ store: PendingApprovalStore, _ record: PendingApproval) async throws -> PendingApproval? {
    let shown = try #require(EgressReview.token(for: record.id, in: try await store.records(now: relatedNow)))
    return try await store.resolve(
        id: record.id, decision: .allowOnce,
        fingerprint: record.fingerprint, identity: record.identity, now: relatedNow,
        onlyIf: { EgressReview.token(for: record.id, in: $0) == shown }
    )
}

private func deny(_ store: PendingApprovalStore, _ record: PendingApproval) async throws {
    _ = try await store.resolve(
        id: record.id, decision: .deny,
        fingerprint: record.fingerprint, identity: record.identity, now: relatedNow
    )
}

private func related(_ store: PendingApprovalStore, _ record: PendingApproval) async throws -> [EgressRelatedGrant] {
    EgressReview.related(to: record.id, in: try await store.records(now: relatedNow))
}

private func pendingIDs(_ store: PendingApprovalStore) async throws -> Set<ApprovalID> {
    Set(try await store.list(now: relatedNow).map(\.id))
}

/// Approving one network proposal never retires another. A proposal is
/// exactly (workspace, host, port), so an approval covers no other
/// awaiting row; same-host rows on other ports stay pending, annotated
/// with the approval they relate to.
struct EgressRelatedGrantTests {
    /// The covered case cannot occur: the ledger already folds a second
    /// same-workspace proposal for the same host:port into the first, so
    /// there is never a second row an approval could supersede.
    @Test func sameHostSamePortNeverQueuesTwice() async throws {
        let store = PendingApprovalStore(baseDirectory: try relatedConfig())
        let workspace = WorkspaceSessionID()
        let first = try await propose(store, workspace: workspace)
        let again = try await propose(store, workspace: workspace)
        #expect(again.id == first.id)
        #expect(try await pendingIDs(store) == [first.id])
        _ = try #require(try await approveReviewed(store, first))
        #expect(try await pendingIDs(store).isEmpty)
    }

    @Test func differentPortStaysPendingAndNamesTheApproval() async throws {
        let store = PendingApprovalStore(baseDirectory: try relatedConfig())
        let workspace = WorkspaceSessionID()
        let https = try await propose(store, port: 443, workspace: workspace)
        let http = try await propose(store, port: 80, workspace: workspace)
        #expect(try await related(store, http).isEmpty)
        _ = try #require(try await approveReviewed(store, https))

        #expect(try await pendingIDs(store) == [http.id])
        let rule443 = try #require(LiveNetworkRule(host: "api.example.com", port: 443))
        #expect(try await related(store, http) == [EgressRelatedGrant(id: https.id, rule: rule443)])

        // Still its own decision: the owner approves it on its own review.
        let approved = try #require(try await approveReviewed(store, http))
        guard case .resolved(let resolution) = approved.state else {
            Issue.record("expected resolved, got \(approved.state)")
            return
        }
        #expect(resolution.decision == .allowOnce)
        let records = try await store.records(now: relatedNow)
        #expect(EgressReview.grants(for: http.identity, in: records).map(\.port) == [80, 443])
    }

    /// No row has a binary dimension (a proposal never carries one), so
    /// the only other axis is the host: a neighbouring host or a parent
    /// domain is not related.
    @Test func otherHostsAreNotRelated() async throws {
        let store = PendingApprovalStore(baseDirectory: try relatedConfig())
        let workspace = WorkspaceSessionID()
        let approved = try await propose(store, host: "api.example.com", workspace: workspace)
        let parent = try await propose(store, host: "example.com", workspace: workspace)
        let sibling = try await propose(store, host: "cdn.example.com", port: 80, workspace: workspace)
        _ = try #require(try await approveReviewed(store, approved))
        #expect(try await related(store, parent).isEmpty)
        #expect(try await related(store, sibling).isEmpty)
        #expect(try await pendingIDs(store) == [parent.id, sibling.id])
    }

    @Test func anotherWorkspacesApprovalTouchesNothingHere() async throws {
        let store = PendingApprovalStore(baseDirectory: try relatedConfig())
        let mine = WorkspaceSessionID()
        let theirs = WorkspaceSessionID()
        let theirApproval = try await propose(store, port: 443, workspace: theirs)
        let mySamePort = try await propose(store, port: 443, workspace: mine)
        let myOtherPort = try await propose(store, port: 80, workspace: mine)
        #expect(mySamePort.id != theirApproval.id)
        _ = try #require(try await approveReviewed(store, theirApproval))

        #expect(try await pendingIDs(store) == [mySamePort.id, myOtherPort.id])
        #expect(try await related(store, mySamePort).isEmpty)
        #expect(try await related(store, myOtherPort).isEmpty)
        let records = try await store.records(now: relatedNow)
        #expect(EgressReview.grants(for: mySamePort.identity, in: records).isEmpty)
    }

    @Test func aDenyRelatesNothing() async throws {
        let store = PendingApprovalStore(baseDirectory: try relatedConfig())
        let workspace = WorkspaceSessionID()
        let denied = try await propose(store, port: 443, workspace: workspace)
        let other = try await propose(store, port: 80, workspace: workspace)
        try await deny(store, denied)
        #expect(try await pendingIDs(store) == [other.id])
        #expect(try await related(store, other).isEmpty)
    }

    /// A related approval is shown only beside a row that still awaits a
    /// human; a resolved, denied or unknown id relates nothing.
    @Test func onlyAwaitingRowsCarryRelations() async throws {
        let store = PendingApprovalStore(baseDirectory: try relatedConfig())
        let workspace = WorkspaceSessionID()
        let https = try await propose(store, port: 443, workspace: workspace)
        let http = try await propose(store, port: 80, workspace: workspace)
        _ = try #require(try await approveReviewed(store, https))
        _ = try #require(try await approveReviewed(store, http))
        #expect(try await related(store, http).isEmpty)
        #expect(try await related(store, https).isEmpty)
        #expect(
            EgressReview.related(
                to: ApprovalID(rawValue: "missing"), in: try await store.records(now: relatedNow)
            ).isEmpty)
    }

    /// The annotation and the review token come from one snapshot, and
    /// the token already binds the grant set the annotation is drawn
    /// from. An owner shown a row without the annotation cannot approve
    /// it after the related grant lands: the bound resolve, which runs
    /// under the store's file lock, refuses and writes nothing.
    @Test func aReviewWithoutTheAnnotationCannotApproveAfterItAppears() async throws {
        let store = PendingApprovalStore(baseDirectory: try relatedConfig())
        let workspace = WorkspaceSessionID()
        let https = try await propose(store, port: 443, workspace: workspace)
        let http = try await propose(store, port: 80, workspace: workspace)
        let shownRecords = try await store.records(now: relatedNow)
        #expect(EgressReview.related(to: http.id, in: shownRecords).isEmpty)
        let shown = try #require(EgressReview.token(for: http.id, in: shownRecords))

        _ = try #require(try await approveReviewed(store, https))
        let refused = try await store.resolve(
            id: http.id, decision: .allowOnce,
            fingerprint: http.fingerprint, identity: http.identity, now: relatedNow,
            onlyIf: { EgressReview.token(for: http.id, in: $0) == shown }
        )
        #expect(refused == nil)
        #expect(try await pendingIDs(store) == [http.id])
        #expect(try await related(store, http).map(\.id) == [https.id])
    }
}
