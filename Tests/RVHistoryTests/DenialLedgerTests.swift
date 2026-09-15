import Foundation
import Testing
import RVDomain
@testable import RVHistory

struct DenialLedgerTests {
    @Test func grokBashResetHard_jsonlBytesMatchToday() throws {
        let record = try decode(LedgerJSONL.grokBashResetHard)
        #expect(record.host == .hook(.grok))
        #expect(record.tool == .bash)
        #expect(record.ruleID == RuleID(pack: .coreGit, pattern: "reset-hard"))
        #expect(record.category == .pack(.coreGit))
        #expect(record.path.isEmpty)
        #expect(try encode(record) == LedgerJSONL.grokBashResetHard)
    }

    @Test func claudeReadEnv_jsonlBytesMatchToday() throws {
        let record = try decode(LedgerJSONL.claudeReadEnv)
        #expect(record.host == .hook(.claude))
        #expect(record.tool == .file(.read))
        #expect(record.ruleID == RuleID(pack: .coreSecrets, pattern: "env"))
        #expect(record.category == .secret(.environment))
        #expect(record.path == "/tmp/rv-oracle/.env")
        #expect(try encode(record) == LedgerJSONL.claudeReadEnv)
    }

    @Test func ttyBashResetHard_jsonlBytesMatchToday() throws {
        let record = try decode(LedgerJSONL.ttyBashResetHard)
        #expect(record.host == .tty)
        #expect(record.tool == .bash)
        #expect(try encode(record) == LedgerJSONL.ttyBashResetHard)
    }

    @Test(
        arguments: [
            (LedgerJSONL.unknownHost, "unknown host"),
            (LedgerJSONL.unknownTool, "unknown tool"),
            (LedgerJSONL.unknownRule, "unknown rule_id"),
            (LedgerJSONL.unknownCategory, "unknown category"),
            (LedgerJSONL.readFileAlias, "file-tool alias is not a ledger tool"),
        ]
    )
    func jsonlUnknownField_throws(line: String, reason: String) {
        #expect(throws: DecodingError.self, "\(reason)") {
            try decode(line)
        }
    }

    @Test func load_skipsUnknownHostLine() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-ledger-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("blocks.jsonl")
        let text = LedgerJSONL.ttyBashResetHard + "\n" + LedgerJSONL.unknownHost + "\n"
            + LedgerJSONL.claudeReadEnv + "\n"
        try Data(text.utf8).write(to: file)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = DenialLedger(fileURL: file).records(asOf: now)
        #expect(rows.count == 2)
        #expect(rows[0].host == .hook(.claude))
        #expect(rows[1].host == .tty)
    }

    @Test func append_records_newestFirst_andAllowNeverWritten() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = DenialLedger(configDirectory: dir)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var older = try decode(LedgerJSONL.claudeReadEnv)
        older.timestamp = now.addingTimeInterval(-10)
        ledger.append(older, now: now)
        ledger.append(try decode(LedgerJSONL.cursorReadSSH), now: now)
        let rows = ledger.records(asOf: now)
        #expect(rows.count == 2)
        #expect(rows[0].ruleID == RuleID(pack: .coreSecrets, pattern: "id-ed25519"))
        #expect(rows[1].path == "/tmp/rv-oracle/.env")
        #expect(rows.allSatisfy { $0.tool != .bash })
    }

    @Test func redact_replacesHomePrefix() {
        #expect(DenialPathRedaction.redact("/Users/ada/.env", home: "/Users/ada") == "~/.env")
        #expect(DenialPathRedaction.redact("$HOME/.ssh/id_rsa", home: "/Users/ada") == "~/.ssh/id_rsa")
        #expect(DenialPathRedaction.redact("/tmp/rv-oracle/.env", home: "/Users/ada") == "/tmp/rv-oracle/.env")
    }

    @Test func pruned_dropsOlderThanSevenDaysAndCapsAt200() throws {
        let ledger = DenialLedger(fileURL: URL(fileURLWithPath: "/tmp/unused-blocks.jsonl"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var template = try decode(LedgerJSONL.ttyBashResetHard)
        template.timestamp = now.addingTimeInterval(-8 * 24 * 60 * 60)
        var records: [DenialLedgerRecord] = [template]
        var env = try decode(LedgerJSONL.claudeReadEnv)
        env.host = .tty
        env.tool = .bash
        for index in 0..<210 {
            env.timestamp = now.addingTimeInterval(TimeInterval(index))
            records.append(env)
        }
        let kept = ledger.pruned(records, now: now.addingTimeInterval(210))
        #expect(kept.count == 200)
        #expect(kept.contains(where: { $0.timestamp < now.addingTimeInterval(-7 * 24 * 60 * 60) }) == false)
    }

    @Test func preferences_missingIsEnabled() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-ledger-pref-\(UUID().uuidString)", isDirectory: true)
        #expect(DenialLedgerPreferences.isEnabled(inConfigDirectory: dir))
    }

    private func decode(_ line: String) throws -> DenialLedgerRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DenialLedgerRecord.self, from: Data(line.utf8))
    }

    private func encode(_ record: DenialLedgerRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        return try #require(String(data: data, encoding: .utf8))
    }
}

private enum LedgerJSONL {
    static let grokBashResetHard =
        #"{"category":"core.git","host":"grok","path":"","rule_id":"core.git:reset-hard","timestamp":"2027-01-15T08:00:00Z","tool":"Bash"}"#
    static let claudeReadEnv =
        #"{"category":"environment","host":"claude","path":"\/tmp\/rv-oracle\/.env","rule_id":"core.secrets:env","timestamp":"2027-01-15T08:00:00Z","tool":"Read"}"#
    static let cursorReadSSH =
        #"{"category":"ssh","host":"cursor","path":"~\/.ssh\/id_ed25519","rule_id":"core.secrets:id-ed25519","timestamp":"2027-01-15T08:00:00Z","tool":"Read"}"#
    static let ttyBashResetHard =
        #"{"category":"core.git","host":"tty","path":"","rule_id":"core.git:reset-hard","timestamp":"2027-01-15T08:00:00Z","tool":"Bash"}"#
    static let unknownHost =
        #"{"category":"core.git","host":"grep","path":"","rule_id":"core.git:reset-hard","timestamp":"2027-01-15T08:00:00Z","tool":"Bash"}"#
    static let unknownTool =
        #"{"category":"core.git","host":"tty","path":"","rule_id":"core.git:reset-hard","timestamp":"2027-01-15T08:00:00Z","tool":"Grep"}"#
    static let unknownRule =
        #"{"category":"core.git","host":"tty","path":"","rule_id":"not-a-rule","timestamp":"2027-01-15T08:00:00Z","tool":"Bash"}"#
    static let unknownCategory =
        #"{"category":"ssh-unknown","host":"tty","path":"","rule_id":"core.git:reset-hard","timestamp":"2027-01-15T08:00:00Z","tool":"Bash"}"#
    static let readFileAlias =
        #"{"category":"environment","host":"claude","path":"","rule_id":"core.secrets:env","timestamp":"2027-01-15T08:00:00Z","tool":"read_file"}"#
}
