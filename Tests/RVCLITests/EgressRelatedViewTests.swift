import Foundation
import Testing
import RVDomain
import RVPolicy
import RVWorkspaceTUI
@testable import RVCLI

private func relatedHome() throws -> HomeDirectory {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-egress-related-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return try #require(HomeDirectory(validating: url.path))
}

private func propose(
    _ store: PendingApprovalStore, port: Int, workspace: WorkspaceSessionID, now: Date
) async throws -> PendingApproval {
    let rule = try #require(LiveNetworkRule(host: "api.example.com", port: port))
    let directory = try #require(WorkingDirectory(validating: "/tmp/rv-egress-related-cli"))
    let request = try #require(
        EgressProposal.request(
            id: PendingApprovalStore.makeID(), rule: rule,
            workspaceSession: workspace, workspaceDirectory: directory
        ))
    return try await store.create(request, now: now)
}

/// Same workspace: 443 approved, 80 still awaiting.
private func approvedAndPending(
    _ store: PendingApprovalStore, now: Date
) async throws -> (approved: PendingApproval, pending: PendingApproval) {
    let workspace = WorkspaceSessionID()
    let approved = try await propose(store, port: 443, workspace: workspace, now: now)
    let pending = try await propose(store, port: 80, workspace: workspace, now: now.addingTimeInterval(1))
    _ = try await store.resolve(
        id: approved.id, decision: .allowOnce,
        fingerprint: approved.fingerprint, identity: approved.identity, now: now
    )
    return (approved, pending)
}

/// `rv egress pending`, `rv egress show` and the `rv tui` review pane
/// keep a same-host proposal on another port listed, and name the
/// approval it relates to.
struct EgressRelatedViewTests {
    @Test func pendingKeepsTheRowAndNamesTheApproval() async throws {
        let home = try relatedHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let store = EgressReviewRun.store(home: home)
        let now = Date()
        let (approved, pending) = try await approvedAndPending(store, now: now)

        let views = try await EgressReviewRun.pending(store: store, now: now)
        #expect(views.map(\.id) == [pending.id.rawValue])
        let expected = EgressRelatedView(id: approved.id.rawValue, host: "api.example.com", port: 443)
        #expect(views.first?.related == [expected])

        let text = EgressReviewRun.prettyPending(views)
        #expect(text.contains("api.example.com:80  awaiting-human"))
        #expect(text.contains("  related approved api.example.com:443 (\(approved.id.rawValue))\n"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            [EgressProposalView].self, from: Data(try EgressReviewRun.robot(views).utf8))
        #expect(decoded == views)
    }

    @Test func showAndThePaneNameTheApproval() async throws {
        let home = try relatedHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let store = EgressReviewRun.store(home: home)
        let now = Date()
        let (approved, pending) = try await approvedAndPending(store, now: now)

        let shown = try await EgressReviewRun.showView(id: pending.id, store: store, now: now)
        #expect(
            EgressReviewRun.prettyShow(shown, rejectionReason: nil)
                .contains("  related approved api.example.com:443 (\(approved.id.rawValue))\n"))

        let result = try await withCLIProcess(home: home) { await WorkspaceReviewQueue().load(now: now) }
        guard case .loaded(let items) = result else {
            Issue.record("expected loaded, got \(result)")
            return
        }
        let rows = items.filter { $0.kind == .pendingEgress }
        #expect(rows.map(\.id) == [.egress(pending.id.rawValue)])
        #expect(rows.first?.summary == "api.example.com:80  related approved :443")
        #expect(
            rows.first?.detail.contains("  related approved api.example.com:443 (\(approved.id.rawValue))") == true)
    }

    /// A row with no related approval reads exactly as before.
    @Test func unrelatedRowsAreUnchanged() async throws {
        let home = try relatedHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let store = EgressReviewRun.store(home: home)
        let now = Date()
        let lone = try await propose(store, port: 443, workspace: WorkspaceSessionID(), now: now)
        let views = try await EgressReviewRun.pending(store: store, now: now)
        #expect(views.map(\.id) == [lone.id.rawValue])
        #expect(views.first?.related == [])
        #expect(EgressReviewRun.prettyPending(views).contains("related") == false)
        let shown = try await EgressReviewRun.showView(id: lone.id, store: store, now: now)
        #expect(EgressReviewRun.prettyShow(shown, rejectionReason: nil).contains("related") == false)
    }

    /// `rv egress show` of an unknown id is still its own refusal.
    @Test func showOfAnUnknownIDIsRefused() async throws {
        let home = try relatedHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        await #expect(throws: EgressReviewError.unknownProposal) {
            _ = try await EgressReviewRun.showView(
                id: ApprovalID(rawValue: "missing"), store: EgressReviewRun.store(home: home), now: Date())
        }
    }
}
