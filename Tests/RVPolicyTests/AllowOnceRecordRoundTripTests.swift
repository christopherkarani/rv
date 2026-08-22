import Foundation
import Testing
import RVDomain
@testable import RVPolicy

@Test func allowOnceRecord_decodesLegacyStringRuleID() throws {
    let legacy = """
    {"schema_version":1,"kind":"pending","code_hash":"abc123","command_fingerprint":"f","command_redacted":"git …","cwd":"/tmp/ws","rule_id":"core.git:reset-hard","created_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-02T00:00:00Z","consumed_at":null}
    """
    let record = try JSONDecoder.allowOnce.decode(AllowOnceRecord.self, from: Data(legacy.utf8))
    #expect(record.ruleID == RuleID(rawValue: "core.git:reset-hard"))
    #expect(record.ruleID?.pack == .coreGit)
    #expect(record.ruleID?.pattern == "reset-hard")
}

@Test func allowOnceRecord_encodesRuleIDAsLegacyString() throws {
    let record = AllowOnceRecord(
        schemaVersion: 1,
        kind: .pending,
        codeHash: "abc123",
        commandFingerprint: "f",
        commandRedacted: "git …",
        cwd: "/tmp/ws",
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        createdAt: Date(timeIntervalSince1970: 1_767_225_600),
        expiresAt: Date(timeIntervalSince1970: 1_767_312_000),
        consumedAt: nil
    )
    let data = try JSONEncoder.allowOnce.encode(record)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"rule_id\":\"core.git:reset-hard\""))

    let decoded = try JSONDecoder.allowOnce.decode(AllowOnceRecord.self, from: data)
    #expect(decoded == record)
}

@Test func allowOnceRecord_nilRuleIDRoundTrips() throws {
    let legacyWithoutKey = """
    {"schema_version":1,"kind":"granted","code_hash":"def456","command_fingerprint":"f","command_redacted":"[redacted]","cwd":"/tmp/ws","created_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-02T00:00:00Z"}
    """
    let decodedLegacy = try JSONDecoder.allowOnce.decode(
        AllowOnceRecord.self,
        from: Data(legacyWithoutKey.utf8)
    )
    #expect(decodedLegacy.ruleID == nil)

    let record = AllowOnceRecord(
        schemaVersion: 1,
        kind: .granted,
        codeHash: "def456",
        commandFingerprint: "f",
        commandRedacted: "[redacted]",
        cwd: "/tmp/ws",
        ruleID: nil,
        createdAt: Date(timeIntervalSince1970: 1_767_225_600),
        expiresAt: Date(timeIntervalSince1970: 1_767_312_000),
        consumedAt: nil
    )
    let data = try JSONEncoder.allowOnce.encode(record)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("rule_id") == false)
    let decoded = try JSONDecoder.allowOnce.decode(AllowOnceRecord.self, from: data)
    #expect(decoded.ruleID == nil)
    #expect(decoded == record)
}

private extension JSONDecoder {
    static var allowOnce: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var allowOnce: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
