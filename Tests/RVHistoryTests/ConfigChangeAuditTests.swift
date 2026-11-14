#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

    /// audit.jsonl as a directory: every append fails.
    private func breakLog(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: AuditLog.fileURL(configDirectory: directory), withIntermediateDirectories: true)
    }

    private func setting(_ direction: ConfigChangeAudit.Direction) -> AuditEvent {
        ConfigChangeAudit.setting("safety.level", from: "normal", to: "strict", direction: direction)
    }

    @Test func settingCarriesPriorNewDirectionAndTheBoundAuthorization() {
        let unbound = setting(.tightening)
        #expect(unbound.kind == .configChanged)
        #expect(unbound.decision == .info)
        #expect(unbound.subject == "safety.level")
        #expect(unbound.source == AuditLedger.Source.audit.rawValue)
        #expect(unbound.detail == [
            "setting": "safety.level", "prior": "normal", "new": "strict", "authorized_by": "none",
            "direction": "tightening",
        ])
        let bound = ConfigChangeAudit.$authorization.withValue("owner (rvd prompt)") { setting(.loosening) }
        #expect(bound.detail["authorized_by"] == "owner (rvd prompt)")
        #expect(bound.detail["direction"] == "loosening")
    }

    @Test func policyEventNamesRevisionsAndHashesOnly() {
        let event = ConfigChangeAudit.policy(
            layer: "repo", change: "save", revision: 4, hash: "abc", ruleCount: 2,
            prior: (revision: 3, hash: "def", ruleCount: 1), direction: .loosening, workspace: "~/w")
        #expect(event.kind == .policyChanged)
        #expect(event.subject == "repo")
        #expect(event.workspace == "~/w")
        #expect(event.detail["revision"] == "4")
        #expect(event.detail["prior_revision"] == "3")
        #expect(event.detail["hash"] == "abc")
        #expect(event.detail["prior_hash"] == "def")
        #expect(event.detail["rule_count"] == "2")
        #expect(AuditEventKind.policyChanged.matches("policy"))
        #expect(AuditEventKind.policyManaged.matches("policy"))
    }

    @Test func workspacePathsShowTheHomeAsTilde() {
        let config = URL(fileURLWithPath: "/Users/someone/.config/rv", isDirectory: true)
        #expect(ConfigChangeAudit.redacted("/Users/someone/src/app", configDirectory: config) == "~/src/app")
        #expect(ConfigChangeAudit.redacted("/srv/app", configDirectory: config) == "/srv/app")
        // A config directory that is not <home>/.config/rv names no home.
        let other = URL(fileURLWithPath: "/tmp/rv-config", isDirectory: true)
        #expect(ConfigChangeAudit.redacted("/Users/someone/src/app", configDirectory: other) == "/Users/someone/src/app")
    }

    @Test func commitRecordsBeforeWritingAndTheChainVerifies() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seenBeforeWrite = try ConfigChangeAudit.commit(setting(.tightening), configDirectory: directory) {
            events(directory).count
        }
        #expect(seenBeforeWrite == 1)
        try ConfigChangeAudit.commit(
            ConfigChangeAudit.setting("guard.mode", from: "unset", to: "observe", direction: .loosening),
            configDirectory: directory
        ) {}
        #expect(events(directory).map(\.subject) == ["safety.level", "guard.mode"])
        let report = try AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: directory)).get()
        #expect(report.isIntact)
        #expect(report.lines == 2)
    }

    @Test func aFailedWriteIsRecordedAsPossiblyPartial() throws {
        struct WriteFailed: Error {}
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: WriteFailed.self) {
            try ConfigChangeAudit.commit(setting(.loosening), configDirectory: directory) { throw WriteFailed() }
        }
        let recorded = events(directory)
        #expect(recorded.map(\.decision) == [.info, .failed])
        #expect(recorded.last?.reason == "write failed; may be partially applied")
    }

    @Test func anUnrecordableLooseningIsNotWritten() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try breakLog(directory)
        var wrote = false
        do {
            try ConfigChangeAudit.commit(setting(.loosening), configDirectory: directory) { wrote = true }
            Issue.record("an unrecordable loosening was committed")
        } catch let error as ConfigChangeUnrecorded {
            #expect(error == ConfigChangeUnrecorded(subject: "safety.level"))
            #expect(error.description.hasPrefix("the audit log could not record the safety.level change"))
        }
        #expect(wrote == false)
    }

    @Test func anUnclassifiedChangeIsTreatedAsLoosening() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try breakLog(directory)
        let unclassified = ConfigChangeAudit.event(.policyManaged, subject: "Acme", detail: ["change": "x"])
        #expect(unclassified.detail["direction"] == nil)
        var wrote = false
        #expect(throws: ConfigChangeUnrecorded.self) {
            try ConfigChangeAudit.commit(unclassified, configDirectory: directory) { wrote = true }
        }
        #expect(wrote == false)
    }

    @Test func anUnrecordableTighteningIsStillMade() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try breakLog(directory)
        var wrote = false
        try ConfigChangeAudit.commit(setting(.tightening), configDirectory: directory) { wrote = true }
        #expect(wrote)
    }

    @Test func aTighteningMadeWhileTheLogIsBusyIsRecordedLate() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ConfigChangeAudit.$lockTimeout.withValue(.milliseconds(50)) {
            let holder = try holdLog(directory)
            var wrote = false
            // The late record waits on the same held lock, so it is lost too;
            // the change is made either way.
            _ = try await ConfigChangeAudit.commitAwaiting(setting(.tightening), configDirectory: directory) {
                wrote = true
            }
            release(holder)
            #expect(wrote)
        }
    }

    /// The flock is held on this thread's own descriptor: no task, no pool.
    private func holdLog(_ directory: URL) throws -> Int32 {
        guard AuditLog.append(setting(.tightening), configDirectory: directory) else { throw CancellationError() }
        let fd = open(AuditLog.fileURL(configDirectory: directory).path, O_RDWR | O_CLOEXEC)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CancellationError() }
        return fd
    }

    private func release(_ fd: Int32) {
        _ = flock(fd, LOCK_UN)
        close(fd)
    }

    @Test func aHeldLogLockRefusesALooseningWithinTheTimeout() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let holder = try holdLog(directory)
        defer { release(holder) }
        let start = ContinuousClock.now
        var wrote = false
        ConfigChangeAudit.$lockTimeout.withValue(.milliseconds(100)) {
            do {
                try ConfigChangeAudit.commit(setting(.loosening), configDirectory: directory) { wrote = true }
                Issue.record("a loosening committed while the log was locked")
            } catch {
                #expect(error is ConfigChangeUnrecorded)
            }
        }
        #expect(wrote == false)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(AuditLog.append(setting(.loosening), configDirectory: directory, lockTimeout: .milliseconds(20)) == false)
    }

    @Test func ocsfMapsGateChangesToDeviceConfigStateChange() throws {
        let event = ConfigChangeAudit.$authorization.withValue("owner (test)") {
            ConfigChangeAudit.setting("guard.hosts.claude", from: "block", to: "observe", direction: .loosening)
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
        // A change is neither Enabled nor Disabled as a whole.
        #expect(object["state_id"] as? Int == 99)
        #expect(object["state"] as? String == "observe")
        #expect(object["status_detail"] == nil)
        #expect(object["severity_id"] as? Int == 1)
        let device = try #require(object["device"] as? [String: Any])
        #expect(device["hostname"] as? String == "h")
        let unmapped = try #require(object["unmapped"] as? [String: Any])
        #expect(unmapped["rv_kind"] as? String == "config.changed")
        let detail = try #require(unmapped["rv_detail"] as? [String: String])
        #expect(detail["prior"] == "block")
        #expect(detail["new"] == "observe")
        #expect(detail["direction"] == "loosening")
        #expect(detail["authorized_by"] == "owner (test)")

        let writeFailed = AuditOCSF.object(ConfigChangeAudit.failed(event), hostName: "h")
        #expect(writeFailed["state_id"] as? Int == 99)
        #expect(writeFailed["severity_id"] as? Int == 3)
        #expect(writeFailed["status_detail"] as? String == "write failed; may be partially applied")
        var invalid = ConfigChangeAudit.event(.policyManaged, subject: "Acme", detail: ["change": "verification-failed"])
        invalid.decision = .failed
        invalid.reason = "signature does not verify"
        let bundle = AuditOCSF.object(invalid, hostName: "h")
        #expect(bundle["class_uid"] as? Int == 5019)
        #expect(bundle["state"] as? String == "verification-failed")
        #expect(bundle["status_detail"] as? String == "signature does not verify")
    }
}
