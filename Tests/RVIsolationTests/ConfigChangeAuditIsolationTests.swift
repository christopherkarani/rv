#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVHistory
import RVIsolation
import Testing

/// `secrets.json` saves and accepted organization serials are recorded in
/// `audit.jsonl` by name and number only, before they take effect.
@Suite("Config change audit: isolation")
struct ConfigChangeAuditIsolationTests {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-config-audit-iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func secret(_ name: String, vault: String) -> SecretDefinition {
        SecretDefinition(
            name: name, description: "hunter2-description",
            source: .azure(vault: vault, name: "db", version: nil), delivery: .environment)
    }

    @Test func secretsSavesRecordNamesOnly() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try SecretsConfiguration(secrets: [secret("DB", vault: "vault-one")]).write(configDirectory: directory).get()
        try SecretsConfiguration(secrets: [secret("DB", vault: "vault-one")]).write(configDirectory: directory).get()
        try SecretsConfiguration(secrets: [secret("DB", vault: "vault-two"), secret("API", vault: "vault-one")])
            .write(configDirectory: directory).get()
        let events = AuditLedger(configDirectory: directory).events(AuditFilter(kinds: ["config.changed"]))
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.subject == "secrets" })
        #expect(events[0].detail["added"] == "DB")
        #expect(events[0].detail["new"] == "1 definitions")
        #expect(events[1].detail["added"] == "API")
        #expect(events[1].detail["changed"] == "DB")
        #expect(events[1].detail["prior"] == "1 definitions")
        let raw = try String(contentsOf: AuditLog.fileURL(configDirectory: directory), encoding: .utf8)
        #expect(raw.contains("hunter2") == false)
        #expect(raw.contains("vault-") == false)
        let report = try AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: directory)).get()
        #expect(report.isIntact)
    }

    @Test func anUnrecordableSecretsSaveIsNotWritten() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: AuditLog.fileURL(configDirectory: directory), withIntermediateDirectories: true)
        let result = SecretsConfiguration(secrets: [secret("DB", vault: "v")]).write(configDirectory: directory)
        guard case .failure(let error) = result else {
            Issue.record("an unrecordable secrets save was written")
            return
        }
        #expect(error == .unrecorded)
        #expect(FileManager.default.fileExists(
            atPath: SecretsConfiguration.fileURL(configDirectory: directory).path) == false)
    }

    @Test func anUnrecordableSecretsRemovalIsStillWritten() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try SecretsConfiguration(secrets: [secret("DB", vault: "v"), secret("API", vault: "v")])
            .write(configDirectory: directory).get()
        let log = AuditLog.fileURL(configDirectory: directory)
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        // Dropping a definition only removes access.
        try SecretsConfiguration(secrets: [secret("DB", vault: "v")]).write(configDirectory: directory).get()
        #expect(try SecretsConfiguration.load(configDirectory: directory).get().secrets.map(\.name) == ["DB"])
        // Changing one is not known to tighten.
        let changed = SecretsConfiguration(secrets: [secret("DB", vault: "other")]).write(configDirectory: directory)
        guard case .failure(let error) = changed else {
            Issue.record("an unrecordable secrets change was written")
            return
        }
        #expect(error == .unrecorded)
    }

    @Test func anAcceptedOrganizationSerialIsRecorded() throws {
        let fixture = try ManagedSerialStoreTests.Fixture()
        try fixture.install(serial: 3)
        #expect(fixture.load().policy != nil)
        try fixture.install(serial: 5)
        #expect(fixture.load().policy != nil)
        #expect(fixture.load().policy != nil)
        let events = AuditLedger(configDirectory: fixture.config).events(AuditFilter(kinds: ["policy.managed"]))
        #expect(events.map { $0.detail["serial"] ?? "" } == ["3", "5"])
        #expect(events.map { $0.detail["prior_serial"] ?? "none" } == ["none", "3"])
        #expect(events.allSatisfy { $0.detail["change"] == "serial-accepted" && $0.detail["signed"] == "true" })
        #expect(events.allSatisfy { $0.detail["authorized_by"]?.hasPrefix("organization signature") == true })
        #expect(events.allSatisfy { $0.detail["sha256"]?.count == 64 })
    }

    @Test func anUnrecordableSerialIsNotAccepted() throws {
        let fixture = try ManagedSerialStoreTests.Fixture()
        try FileManager.default.createDirectory(
            at: AuditLog.fileURL(configDirectory: fixture.config), withIntermediateDirectories: true)
        try fixture.install(serial: 3)
        #expect(fixture.load().invalidReason?.contains("could not record organization policy serial 3") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.state.path) == false)
    }
}
