import Foundation
import Testing
import RVHistory
import RVPolicy
@testable import RVService

/// Organization bundle transitions a running process sees are recorded as
/// `policy.managed`; a raised serial is left to `ManagedSerialStore`.
@Suite("Managed gate audit")
struct ManagedGateAuditTests {
    private func active(sha: String, serial: Int?) -> ManagedPolicyState {
        var policy = ManagedPolicy()
        policy.serial = serial
        policy.organization = "Acme"
        return .active(ManagedPolicyBundle(
            policy: policy, sha256: sha, isSigned: true, directory: "/etc/rv/managed", signingKey: 2))
    }

    @Test func transitionsMapToChanges() throws {
        let signed = ManagedGateAudit.Seen(active(sha: "a", serial: 3))
        let failed = try #require(ManagedGateAudit.event(from: signed, to: .invalid("signature does not verify")))
        #expect(failed.kind == .policyManaged)
        #expect(failed.decision == .failed)
        #expect(failed.reason == "signature does not verify")
        #expect(failed.detail["change"] == "verification-failed")
        #expect(failed.detail["prior_serial"] == "3")

        let removed = try #require(ManagedGateAudit.event(from: signed, to: .none))
        #expect(removed.detail["change"] == "removed")

        let back = try #require(ManagedGateAudit.event(from: ManagedGateAudit.Seen(.none), to: active(sha: "a", serial: 3)))
        #expect(back.detail["change"] == "verified")
        #expect(back.subject == "Acme")
        #expect(back.detail["authorized_by"] == "organization signature (key 2)")

        let swapped = try #require(ManagedGateAudit.event(from: signed, to: active(sha: "b", serial: 3)))
        #expect(swapped.detail["change"] == "changed")
        #expect(swapped.detail["prior_sha256"] == "a")
        #expect(swapped.detail["sha256"] == "b")

        #expect(ManagedGateAudit.event(from: signed, to: active(sha: "c", serial: 4)) == nil)
    }

    @Test func theFirstStateIsABaselineAndTransitionsAreRecorded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-managed-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func recorded() -> [String] {
            AuditLedger(configDirectory: directory).events(AuditFilter(kinds: ["policy.managed"]))
                .map { $0.detail["change"] ?? "" }
        }
        ManagedGateAudit.observe(active(sha: "a", serial: 3), configDirectory: directory)
        ManagedGateAudit.observe(active(sha: "a", serial: 3), configDirectory: directory)
        #expect(recorded().isEmpty)
        ManagedGateAudit.observe(.invalid("rollback"), configDirectory: directory)
        ManagedGateAudit.observe(.invalid("rollback"), configDirectory: directory)
        ManagedGateAudit.observe(active(sha: "a", serial: 3), configDirectory: directory)
        #expect(recorded() == ["verification-failed", "verified"])
    }

    @Test func anUnrecordedTransitionIsRetried() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-managed-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AuditLog.fileURL(configDirectory: directory)
        ManagedGateAudit.observe(active(sha: "a", serial: 3), configDirectory: directory)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        ManagedGateAudit.observe(.none, configDirectory: directory)
        try FileManager.default.removeItem(at: log)
        ManagedGateAudit.observe(.none, configDirectory: directory)
        let changes = AuditLedger(configDirectory: directory).events(AuditFilter(kinds: ["policy.managed"]))
        #expect(changes.map { $0.detail["change"] ?? "" } == ["removed"])
    }
}
