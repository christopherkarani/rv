import Foundation
import Testing
@testable import RVHistory

struct DenialLedgerTests {
    @Test func append_list_newestFirst_andAllowNeverWritten() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = DenialLedger(configDirectory: dir)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.append(
            DenialLedgerRecord(
                timestamp: now.addingTimeInterval(-10),
                host: "claude",
                tool: "Read",
                ruleID: "core.secrets:env",
                category: "environment",
                path: "/tmp/rv-oracle/.env"
            ),
            now: now
        )
        ledger.append(
            DenialLedgerRecord(
                timestamp: now,
                host: "claude",
                tool: "Read",
                ruleID: "core.secrets:id-ed25519",
                category: "ssh",
                path: "~/.ssh/id_ed25519"
            ),
            now: now
        )
        let rows = ledger.list(now: now)
        #expect(rows.count == 2)
        #expect(rows[0].ruleID == "core.secrets:id-ed25519")
        #expect(rows[1].path == "/tmp/rv-oracle/.env")
        #expect(rows.allSatisfy { $0.tool != "allow" })
    }

    @Test func redact_replacesHomePrefix() {
        #expect(DenialPathRedaction.redact("/Users/ada/.env", home: "/Users/ada") == "~/.env")
        #expect(DenialPathRedaction.redact("$HOME/.ssh/id_rsa", home: "/Users/ada") == "~/.ssh/id_rsa")
        #expect(DenialPathRedaction.redact("/tmp/rv-oracle/.env", home: "/Users/ada") == "/tmp/rv-oracle/.env")
    }

    @Test func prune_dropsOlderThanSevenDaysAndCapsAt200() {
        let ledger = DenialLedger(fileURL: URL(fileURLWithPath: "/tmp/unused-blocks.jsonl"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var records: [DenialLedgerRecord] = [
            DenialLedgerRecord(
                timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60),
                host: "tty",
                tool: "Bash",
                ruleID: "core.git:reset-hard",
                category: "core.git",
                path: ""
            )
        ]
        for index in 0..<210 {
            records.append(
                DenialLedgerRecord(
                    timestamp: now.addingTimeInterval(TimeInterval(index)),
                    host: "tty",
                    tool: "Bash",
                    ruleID: "core.secrets:env",
                    category: "environment",
                    path: ".env"
                )
            )
        }
        let kept = ledger.prune(records, now: now.addingTimeInterval(210))
        #expect(kept.count == 200)
        #expect(kept.contains(where: { $0.timestamp < now.addingTimeInterval(-7 * 24 * 60 * 60) }) == false)
    }

    @Test func preferences_missingIsEnabled() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-ledger-pref-\(UUID().uuidString)", isDirectory: true)
        #expect(DenialLedgerPreferences.isEnabled(inConfigDirectory: dir))
    }
}
