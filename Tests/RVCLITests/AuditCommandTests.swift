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
}
