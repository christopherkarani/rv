import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy
import RVWorkspaceTUI
@testable import RVCLI

private func reviewHome() throws -> HomeDirectory {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-tui-review-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return try #require(HomeDirectory(validating: url.path))
}

private func pendingProposal(home: HomeDirectory, host: String = "api.example.com") async throws -> PendingApproval {
    let store = EgressReviewRun.store(home: home)
    let rule = try #require(LiveNetworkRule(host: host, port: 443))
    let directory = try #require(WorkingDirectory(validating: "/tmp/rv-tui-review"))
    let request = try #require(EgressProposal.request(
        id: PendingApprovalStore.makeID(), rule: rule,
        workspaceSession: WorkspaceSessionID(), workspaceDirectory: directory
    ))
    return try await store.create(request, now: Date())
}

/// The review token the pane showed for `record`, as `rv tui` holds it.
private func shownToken(_ record: PendingApproval, home: HomeDirectory) async throws -> String? {
    let result = try await withCLIProcess(home: home) { await WorkspaceReviewQueue().load(now: Date()) }
    guard case .loaded(let items) = result else { return nil }
    return items.first { $0.id == .egress(record.id.rawValue) }?.reviewToken
}

private func stillAwaiting(_ record: PendingApproval, home: HomeDirectory) async throws -> Bool {
    let loaded = try await EgressReviewRun.store(home: home).load(id: record.id, now: Date())
    if case .awaitingHuman = loaded.state { return true }
    return false
}

struct WorkspaceReviewQueueTests {
    @Test func loadMergesPendingEgressAndExplainedBlocks() async throws {
        let home = try reviewHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let proposal = try await pendingProposal(home: home)
        let now = Date()
        DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home)).append(
            DenialLedgerRecord(
                timestamp: now, host: .hook(.claude), tool: .bash,
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                category: .pack(.coreGit), path: ""
            ),
            now: now
        )
        let result = try await withCLIProcess(home: home) {
            await WorkspaceReviewQueue().load(now: now)
        }
        guard case .loaded(let items) = result else {
            Issue.record("expected loaded, got \(result)")
            return
        }
        let pending = try #require(items.first { $0.kind == .pendingEgress })
        #expect(pending.id == .egress(proposal.id.rawValue))
        #expect(pending.reviewToken != nil)
        #expect(items.first { $0.kind == .block }?.reviewToken == nil)
        #expect(pending.summary == "api.example.com:443")
        #expect(pending.detail.contains("  egress api.example.com:443"))
        #expect(pending.detail.contains("  state awaiting-human"))
        let block = try #require(items.first { $0.kind == .block })
        #expect(block.summary == "core.git/reset-hard  Bash")
        // The detail is the explain renderer's view of the block.
        #expect(block.detail.first == "RV EXPLAIN")
        #expect(block.detail.contains { $0.contains("core.git/reset-hard") })
        #expect(block.detail.contains { $0.contains("Bash blocked (core.git)") })
        #expect(block.detail.joined().contains("\u{1b}") == false)
    }

    @Test func loadFailsClosedWithoutHome() async throws {
        let result = try await withCLIProcess(environment: [:]) {
            await WorkspaceReviewQueue().load(now: Date())
        }
        #expect(result == .failed(WorkspaceReviewQueue.homeMissing))
    }

    @Test func identicalBlocksKeepDistinctStableIDs() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let record = DenialLedgerRecord(
            timestamp: at, host: .tty, tool: .bash,
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), category: .pack(.coreGit), path: ""
        )
        let ids = WorkspaceReviewQueue.blockItems([record, record]).map(\.id)
        #expect(Set(ids).count == 2)
        #expect(ids == WorkspaceReviewQueue.blockItems([record, record]).map(\.id))
    }

    /// The pane's approve enters the same door as `rv egress approve`: even
    /// with a TTY, no owner authentication means a refusal, and the
    /// proposal stays awaiting a human.
    @Test func approveNeedsOwnerAuthentication() async throws {
        let home = try reviewHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let proposal = try await pendingProposal(home: home)
        let token = try await shownToken(proposal, home: home)
        let outcome = try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true, ownerAuthOutcome: .failed
        ) {
            await WorkspaceReviewQueue().approve(egress: proposal.id.rawValue, reviewToken: token)
        }
        #expect(outcome == .refused("approve refused: device-owner authentication required"))
        #expect(try await stillAwaiting(proposal, home: home))
    }

    @Test func approveWithTheShownTokenResolves() async throws {
        let home = try reviewHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let proposal = try await pendingProposal(home: home)
        let token = try await shownToken(proposal, home: home)
        let outcome = try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true, ownerAuthOutcome: .authenticated
        ) {
            await WorkspaceReviewQueue().approve(egress: proposal.id.rawValue, reviewToken: token)
        }
        #expect(outcome == .completed("approved api.example.com:443 (live within seconds; no restart)"))
        #expect(try await stillAwaiting(proposal, home: home) == false)
    }

    /// The pane showed the proposal, then a grant landed for the same
    /// workspace: the approval binds what was shown, so it is refused
    /// before any prompt, and the row still awaits a fresh review.
    @Test func approveRefusedWhenGrantsMovedAfterThePaneShowedIt() async throws {
        let home = try reviewHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let store = EgressReviewRun.store(home: home)
        let workspace = WorkspaceSessionID()
        let directory = try #require(WorkingDirectory(validating: "/tmp/rv-tui-review"))
        func propose(_ host: String) async throws -> PendingApproval {
            let rule = try #require(LiveNetworkRule(host: host, port: 443))
            let request = try #require(EgressProposal.request(
                id: PendingApprovalStore.makeID(), rule: rule,
                workspaceSession: workspace, workspaceDirectory: directory
            ))
            return try await store.create(request, now: Date())
        }
        let proposal = try await propose("api.example.com")
        let sibling = try await propose("cdn.example.net")
        let token = try await shownToken(proposal, home: home)
        _ = try await store.resolve(
            id: sibling.id, decision: .allowOnce,
            fingerprint: sibling.fingerprint, identity: sibling.identity, now: Date()
        )
        // `.failed` owner auth: a refusal that reached the prompt would
        // read "device-owner authentication required" instead.
        let outcome = try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true, ownerAuthOutcome: .failed
        ) {
            await WorkspaceReviewQueue().approve(egress: proposal.id.rawValue, reviewToken: token)
        }
        #expect(outcome == .refused("approve refused: egress grants changed since you reviewed this; review it again"))
        #expect(try await stillAwaiting(proposal, home: home))
    }

    @Test func approveWithoutAShownTokenIsRefused() async throws {
        let home = try reviewHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let proposal = try await pendingProposal(home: home)
        let outcome = try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true, ownerAuthOutcome: .authenticated
        ) {
            await WorkspaceReviewQueue().approve(egress: proposal.id.rawValue, reviewToken: nil)
        }
        #expect(outcome == .refused(
            "approve refused: nothing binds this approval to what you reviewed; review it again"))
        #expect(try await stillAwaiting(proposal, home: home))
    }

    @Test func denyNeedsOwnerAuthentication() async throws {
        let home = try reviewHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let proposal = try await pendingProposal(home: home)
        let outcome = try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true, ownerAuthOutcome: .failed
        ) {
            await WorkspaceReviewQueue().deny(egress: proposal.id.rawValue, reason: "tracker")
        }
        #expect(outcome == .refused("deny refused: device-owner authentication required"))
        #expect(try await stillAwaiting(proposal, home: home))
    }

    @Test func approveWithoutHomeRefuses() async throws {
        let outcome = try await withCLIProcess(environment: [:]) {
            await WorkspaceReviewQueue().approve(egress: "p1", reviewToken: nil)
        }
        #expect(outcome == .refused("approve refused: \(WorkspaceReviewQueue.homeMissing)"))
    }

    @Test func refusalWordingCoversEveryCeremonyError() {
        #expect(WorkspaceReviewQueue.refusal(AllowOnceError.ttyRequired)
            == "requires an interactive TTY (stdin and stdout)")
        #expect(WorkspaceReviewQueue.refusal(AllowOnceError.robotRefused) == "--json/--robot refused")
        #expect(WorkspaceReviewQueue.refusal(EgressReviewError.storeUnavailable) == "store unavailable")
        #expect(WorkspaceReviewQueue.refusal(AllowOnceError.redemptionChanged)
            == "proposal changed during review; retry")
        #expect(WorkspaceReviewQueue.refusal(EgressReviewError.notAwaiting("expired")) == "proposal is expired")
        #expect(WorkspaceReviewQueue.refusal(AllowOnceAuthError.required) == "device-owner authentication required")
        #expect(WorkspaceReviewQueue.refusal(AllowOnceAuthError.throttled)
            == "too many authentication prompts; wait and retry")
        #expect(WorkspaceReviewQueue.refusal(ValidationError("boundary")) == "boundary")
        #expect(WorkspaceReviewQueue.refusal(CocoaError(.fileNoSuchFile)) == "unexpected error")
    }
}
