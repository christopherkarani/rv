import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy
@testable import RVCLI

struct AuditCommandTests {
    @Test func registeredWithHelpAndDefaultTail() throws {
        let names = RV.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("audit"))
        #expect(HelpDispatch.topic(arguments: ["audit", "--help"]) == .audit)
        #expect(HelpDispatch.topic(arguments: ["help", "audit"]) == .audit)
        #expect(Audit.configuration.defaultSubcommand == AuditTail.self)
    }

    @Test(arguments: [
        ("90s", 90.0), ("30m", 1_800.0), ("24h", 86_400.0), ("7d", 604_800.0), ("0h", 0.0),
    ])
    func durationsParse(text: String, seconds: Double) {
        #expect(AuditRun.duration(text) == seconds)
    }

    @Test(arguments: ["", "h", "10", "-1h", "1w", "1.5x"])
    func badDurationsAreRejected(text: String) {
        #expect(AuditRun.duration(text) == nil)
        #expect(throws: (any Error).self) {
            try AuditRun.filter(since: text, kinds: [], limit: nil, now: Date())
        }
    }

    @Test func emptyHomeIsQuiet() throws {
        let home = try isolatedHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let events = AuditRun.events(home: home, filter: AuditFilter())
        #expect(events.isEmpty)
        #expect(AuditRun.pretty(events) == "")
        #expect(AuditRun.jsonArray(events) == "[]\n")
        #expect(AuditRun.jsonLines(events) == "")
    }

    @Test func joinsRealLedgerWritersIntoOneTimeline() throws {
        let home = try isolatedHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let config = RVPolicyPaths.configDirectory(home: home)
        let now = Date()
        DenialLedger(configDirectory: config).append(
            DenialLedgerRecord(
                timestamp: now.addingTimeInterval(-120),
                host: .hook(.claude),
                tool: .bash,
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                category: .pack(.coreGit),
                path: ""
            ),
            now: now
        )
        let egress = #"{"host":"exfil.example","port":"443","reason":"denied-policy","recordedAt":"\#(now.addingTimeInterval(-60).timeIntervalSince1970)"}"#
        try Data((egress + "\n").utf8).write(to: config.appendingPathComponent("egress-denials.jsonl"))
        AuditLog.append(
            AuditEvent(
                time: now.addingTimeInterval(-10),
                kind: .secretUse,
                decision: .allowed,
                subject: "STRIPE_SECRET_KEY",
                source: "audit.jsonl",
                detail: ["fingerprint": "00112233aabbccdd"]
            ),
            configDirectory: config
        )

        let all = AuditRun.events(home: home, filter: AuditFilter())
        #expect(all.map(\.kind) == [.commandDenied, .egressDenied, .secretUse])

        let pretty = AuditRun.pretty(all)
        let lines = pretty.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].contains("denied   command.denied  core.git:reset-hard  agent=claude"))
        #expect(lines[1].contains("egress.denied  exfil.example:443  reason=denied-policy"))
        #expect(lines[2].contains("allowed  secret.use  STRIPE_SECRET_KEY"))

        let recentEgress = AuditRun.events(
            home: home,
            filter: try AuditRun.filter(since: "90s", kinds: ["egress"], limit: nil, now: now)
        )
        #expect(recentEgress.map(\.subject) == ["exfil.example:443"])

        let exported = AuditRun.jsonLines(all).split(separator: "\n")
        #expect(exported.count == 3)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try exported.map { try decoder.decode(AuditEvent.self, from: Data($0.utf8)) }
        #expect(roundTrip.map(\.subject) == all.map(\.subject))
        #expect(roundTrip.allSatisfy { $0.schema == "rv.audit.v1" })
        #expect(AuditRun.jsonLines(all).contains("STRIPE_SECRET_KEY"))
        #expect(AuditRun.jsonArray(all).hasPrefix("["))
    }

    @Test func toolNameIsEscapedOnSubjectReasonRobotAndExport() throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let raw = "\u{1B}[2J\u{1B}[H" + sentence + "\u{2028}" + sentence + "\u{202E}" + sentence
        let event = AuditEvent(
            time: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .mcpCall,
            decision: .denied,
            subject: "github/\(raw)",
            reason: "rv policy denies github tool \(raw)",
            agent: raw,
            source: "audit.jsonl"
        )
        let pretty = AuditRun.pretty([event])
        #expect(pretty.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(pretty.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(pretty.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(pretty.contains("\\u001b[2J"))
        #expect(pretty.contains("\\u2028"))
        #expect(pretty.contains("\\u202e"))
        #expect(pretty.contains("github/"))
        #expect(pretty.contains("reason="))
        let lines = pretty.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
        #expect(lines.contains(sentence) == false)

        let robot = AuditRun.jsonArray([event])
        let exported = AuditRun.jsonLines([event])
        func row(_ text: String) throws -> [String: Any] {
            #expect(text.unicodeScalars.contains { $0.value == 0x2028 } == false)
            #expect(text.unicodeScalars.contains { $0.value == 0x202E } == false)
            #expect(text.contains("\\u2028"))
            #expect(text.contains("\\u202e"))
            #expect(text.unicodeScalars.contains { $0.value == 0x1B } == false)
            let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
            if let rows = parsed as? [[String: Any]], let first = rows.first { return first }
            return try #require(parsed as? [String: Any])
        }
        let robotRow = try row(robot)
        let exportedRow = try row(exported)
        #expect(robotRow["subject"] as? String == "github/\(raw)")
        #expect(robotRow["reason"] as? String == "rv policy denies github tool \(raw)")
        #expect(exportedRow["subject"] as? String == "github/\(raw)")
        #expect(exportedRow["reason"] as? String == "rv policy denies github tool \(raw)")
        let ocsf = try #require(AuditOCSF.jsonLine(event, hostName: "h"))
        #expect(ocsf.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(ocsf.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(ocsf.contains("\\u2028"))
        #expect(ocsf.contains("\\u202e"))
        #expect(try JSONSerialization.jsonObject(with: Data(ocsf.utf8)) is [String: Any])
    }
}

@Suite("rv audit verify")
struct AuditVerifyTests {
    @Test func reportsAnIntactChainAndTheFirstBreak() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for subject in ["a", "b", "c"] {
            _ = AuditLog.append(
                AuditEvent(time: Date(), kind: .mcpCall, decision: .allowed, subject: subject, source: "test"),
                configDirectory: directory)
        }
        let url = AuditLog.fileURL(configDirectory: directory)
        let intact = try AuditVerifyRun.check(url).get()
        #expect(AuditVerifyRun.text(intact, path: url.path).hasPrefix("audit chain intact: 3 lines, head "))

        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        lines[1] = lines[1].replacingOccurrences(of: #""subject":"b""#, with: #""subject":"x""#)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        let broken = try AuditVerifyRun.check(url).get()
        #expect(AuditVerifyRun.text(broken, path: url.path)
            == "audit chain BROKEN at line 3 of \(url.path): prev does not match line 2\n"
            + "  lines 1-2 are intact; line 3 or the one before it was edited, removed, inserted, or reordered\n")
    }

    @Test func notesLinesWrittenBeforeTheChain() {
        let report = AuditChainReport(lines: 5, unchained: 2, head: String(repeating: "a", count: 64), firstBreak: nil)
        #expect(AuditVerifyRun.text(report, path: "/x")
            == "audit chain intact: 5 lines, head \(String(repeating: "a", count: 64))\n"
            + "  the first 2 lines predate the chain and are not covered\n")
        let empty = AuditChainReport(lines: 0, unchained: 0, head: AuditChain.genesis, firstBreak: nil)
        #expect(AuditVerifyRun.text(empty, path: "/x") == "no audit lines yet (/x)\n")
    }
}
