import Foundation
import Testing
@testable import RVHistory

@Suite("Config change audit")
struct ConfigChangeAuditTests {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-config-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func events(_ directory: URL) -> [AuditEvent] {
        AuditLedger(configDirectory: directory).events(AuditFilter(kinds: ["config", "policy"]))
    }

    @Test func settingCarriesPriorNewAndTheBoundAuthorization() {
        let unbound = ConfigChangeAudit.setting("safety.level", from: "normal", to: "strict")
        #expect(unbound.kind == .configChanged)
        #expect(unbound.decision == .info)
        #expect(unbound.subject == "safety.level")
        #expect(unbound.source == AuditLedger.Source.audit.rawValue)
        #expect(unbound.detail == [
            "setting": "safety.level", "prior": "normal", "new": "strict", "authorized_by": "none",
        ])
        let bound = ConfigChangeAudit.$authorization.withValue("owner (rvd prompt)") {
            ConfigChangeAudit.setting("safety.level", from: "normal", to: "strict")
        }
        #expect(bound.detail["authorized_by"] == "owner (rvd prompt)")
    }

    @Test func policyEventNamesRevisionsAndHashesOnly() {
        let event = ConfigChangeAudit.policy(
            layer: "repo", change: "save", revision: 4, hash: "abc", ruleCount: 2,
            prior: (revision: 3, hash: "def", ruleCount: 1), workspace: "/w")
        #expect(event.kind == .policyChanged)
        #expect(event.subject == "repo")
        #expect(event.workspace == "/w")
        #expect(event.detail["revision"] == "4")
        #expect(event.detail["prior_revision"] == "3")
        #expect(event.detail["hash"] == "abc")
        #expect(event.detail["prior_hash"] == "def")
        #expect(event.detail["rule_count"] == "2")
        #expect(AuditEventKind.policyChanged.matches("policy"))
        #expect(AuditEventKind.policyManaged.matches("policy"))
    }

    @Test func commitRecordsBeforeWritingAndTheChainVerifies() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = ConfigChangeAudit.setting("safety.level", from: "normal", to: "strict")
        let seenBeforeWrite = try ConfigChangeAudit.commit(event, configDirectory: directory) {
            events(directory).count
        }
        #expect(seenBeforeWrite == 1)
        try ConfigChangeAudit.commit(
            ConfigChangeAudit.setting("guard.mode", from: "unset", to: "observe"), configDirectory: directory
        ) {}
        #expect(events(directory).map(\.subject) == ["safety.level", "guard.mode"])
        let report = try AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: directory)).get()
        #expect(report.isIntact)
        #expect(report.lines == 2)
    }

    @Test func aFailedWriteIsRecordedAsFailed() throws {
        struct WriteFailed: Error {}
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = ConfigChangeAudit.setting("packs", from: "a", to: "b")
        #expect(throws: WriteFailed.self) {
            try ConfigChangeAudit.commit(event, configDirectory: directory) { throw WriteFailed() }
        }
        let recorded = events(directory)
        #expect(recorded.map(\.decision) == [.info, .failed])
        #expect(recorded.last?.reason == "not saved")
    }

    @Test func anUnrecordableChangeIsNotWritten() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // audit.jsonl as a directory: every append fails.
        try FileManager.default.createDirectory(
            at: AuditLog.fileURL(configDirectory: directory), withIntermediateDirectories: true)
        var wrote = false
        do {
            try ConfigChangeAudit.commit(
                ConfigChangeAudit.setting("safety.level", from: "normal", to: "strict"), configDirectory: directory
            ) { wrote = true }
            Issue.record("an unrecordable change was committed")
        } catch let error as ConfigChangeUnrecorded {
            #expect(error == ConfigChangeUnrecorded(subject: "safety.level"))
        }
        #expect(wrote == false)
    }

    @Test func ocsfMapsGateChangesToDeviceConfigStateChange() throws {
        let event = ConfigChangeAudit.$authorization.withValue("owner (test)") {
            ConfigChangeAudit.setting("guard.hosts.claude", from: "block", to: "observe")
        }
        let line = try #require(AuditOCSF.jsonLine(event, hostName: "h"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["class_uid"] as? Int == 5019)
        #expect(object["class_name"] as? String == "Device Config State Change")
        #expect(object["category_uid"] as? Int == 5)
        #expect(object["category_name"] as? String == "Discovery")
        #expect(object["activity_id"] as? Int == 1)
        #expect(object["activity_name"] as? String == "Log")
        #expect(object["type_uid"] as? Int == 501_901)
        #expect(object["state_id"] as? Int == 2)
        #expect(object["severity_id"] as? Int == 1)
        let device = try #require(object["device"] as? [String: Any])
        #expect(device["hostname"] as? String == "h")
        let unmapped = try #require(object["unmapped"] as? [String: Any])
        #expect(unmapped["rv_kind"] as? String == "config.changed")
        let detail = try #require(unmapped["rv_detail"] as? [String: String])
        #expect(detail["prior"] == "block")
        #expect(detail["new"] == "observe")
        #expect(detail["authorized_by"] == "owner (test)")

        for kind in [AuditEventKind.policyChanged, .policyManaged] {
            let other = AuditEvent(time: Date(), kind: kind, decision: .failed, subject: "s", source: "audit.jsonl")
            let mapped = AuditOCSF.object(other, hostName: "h")
            #expect(mapped["class_uid"] as? Int == 5019)
            #expect(mapped["state_id"] as? Int == 99)
            #expect(mapped["severity_id"] as? Int == 3)
        }
    }
}
