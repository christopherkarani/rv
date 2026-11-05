import Foundation
import Testing
import RVHistory
@testable import RVCLI

/// SEC-002: agent-influenced text in egress and audit-verify output renders escaped.
struct UntrustedTextEscapeTests {
    private static let hostile = "evil\u{1b}]52;x\u{7}\u{9b}\u{202e}\u{2028}.example.com"
    /// `hostile` written once through `DisplayedText.field`.
    private static let hostileFielded = #"evil\u001b]52;x\u0007\u009b\u202e\u2028.example.com"#
    private static let asciiOnly = "a.example.com"

    private func proposal(host: String, reason: String) -> EgressProposalView {
        EgressProposalView(
            id: "id-1", host: host, port: 443, state: "awaiting-human", reason: reason,
            createdAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 60))
    }

    private func denial(host: String, reason: String) -> EgressDenialView {
        EgressDenialView(host: host, port: 443, reason: reason, recordedAt: Date(timeIntervalSince1970: 0))
    }

    /// Scalar-level, not `String.contains`: that is grapheme-aware.
    private func expectClean(_ text: String) {
        let raw = text.unicodeScalars.filter { [0x1B, 0x07, 0x9B, 0x202E, 0x2028].contains($0.value) }
        #expect(raw.isEmpty, "raw scalars: \(raw.map { String(format: "U+%04X", $0.value) })")
    }

    @Test func humanEgressViewsEscape() {
        let view = proposal(host: Self.hostile, reason: Self.hostile)
        expectClean(EgressReviewRun.prettyPending([view]))
        expectClean(EgressReviewRun.prettyShow(view, rejectionReason: Self.hostile))
        expectClean(EgressReviewRun.prettyDenials([denial(host: Self.hostile, reason: Self.hostile)]))
    }

    @Test func robotEgressViewsEscape() throws {
        let view = proposal(host: Self.hostile, reason: Self.hostile)
        expectClean(try EgressReviewRun.robot([view]))
        expectClean(try EgressReviewRun.robotShow(view, rejectionReason: Self.hostile))
        let robotDenials = try EgressReviewRun.robotDenials([denial(host: Self.hostile, reason: Self.hostile)])
        expectClean(robotDenials)
        #expect(robotDenials.contains("\\u202e"))
    }

    /// Escaped once: robot pending/show decode back to the exact values.
    @Test func robotEgressViewsRoundTrip() throws {
        let view = proposal(host: Self.hostile, reason: Self.hostile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pending = try EgressReviewRun.robot([view])
        #expect(try decoder.decode([EgressProposalView].self, from: Data(pending.utf8)) == [view])
        let show = try EgressReviewRun.robotShow(view, rejectionReason: Self.hostile)
        let snapshot = try decoder.decode(EgressReviewRun.ShowSnapshot.self, from: Data(show.utf8))
        #expect(snapshot.proposal == view)
        #expect(snapshot.rejectionReason == Self.hostile)
    }

    @Test func plainASCIIRobotBytesUnchanged() throws {
        let view = proposal(host: Self.asciiOnly, reason: "no rule")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        #expect(try EgressReviewRun.robot([view]) == String(decoding: try encoder.encode([view]), as: UTF8.self))
        let denials = [denial(host: Self.asciiOnly, reason: "no rule")]
        #expect(try EgressReviewRun.robotDenials(denials) == String(decoding: try encoder.encode(denials), as: UTF8.self))
    }

    @Test func auditVerifyEscapes() throws {
        let broken = AuditChainReport(
            lines: 2, unchained: 0, head: "h",
            firstBreak: .init(line: 2, reason: "bad \(Self.hostile)"))
        expectClean(try AuditVerifyRun.json(broken))
        expectClean(AuditVerifyRun.text(broken, path: "/tmp/\(Self.hostile)"))
    }

    @Test func auditVerifyPlainASCIIUnchanged() throws {
        let ok = AuditChainReport(lines: 1, unchained: 0, head: "abc", firstBreak: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        #expect(try AuditVerifyRun.json(ok) == String(decoding: try! encoder.encode(ok), as: UTF8.self) + "\n")
    }

    /// AC-007 for `rv egress denials`: a hostile host in the proxy denial
    /// log, parsed as the command parses it, prints escaped once in human
    /// mode; robot mode stays one valid JSON value that decodes back to the
    /// exact host (escaped once, not twice).
    @Test func denialsLogHostEscapesOnce() throws {
        let line = try JSONSerialization.data(withJSONObject: [
            "host": Self.hostile, "port": "443", "reason": "no rule", "recordedAt": "0",
        ])
        let views = EgressReviewRun.parseDenialsLog(String(decoding: line, as: UTF8.self))
        #expect(views.map(\.host) == [Self.hostile])

        let human = EgressReviewRun.prettyDenials(views)
        expectClean(human)
        #expect(Data(human.utf8).range(of: Data("\(Self.hostileFielded):443  no rule".utf8)) != nil)

        let robot = try EgressReviewRun.robotDenials(views)
        expectClean(robot)
        let rows = try #require(JSONSerialization.jsonObject(with: Data(robot.utf8)) as? [[String: Any]])
        #expect(rows.first?["host"] as? String == Self.hostile)
    }

    /// SEC-002: `rv secrets describe` robot output escapes a hostile
    /// description once and keeps plain-ASCII bytes identical to the seam.
    @Test func secretsDescribeRobotEscapes() throws {
        func report(_ description: String) -> SecretsRun.DescribeReport {
            SecretsRun.DescribeReport(secrets: [
                SecretsRun.DescribeRow(
                    name: "TOKEN", description: description, type: nil, delivery: "environment", source: "keychain"),
            ])
        }
        let robot = SecretsRun.describeOutput(report(Self.hostile), robot: true)
        expectClean(robot)
        let object = try #require(JSONSerialization.jsonObject(with: Data(robot.utf8)) as? [String: Any])
        let rows = try #require(object["secrets"] as? [[String: Any]])
        #expect(rows.first?["description"] as? String == Self.hostile)
        let plain = report("plain text")
        #expect(SecretsRun.describeOutput(plain, robot: true) == (try RobotJSON.encode(plain, options: .pretty)))
        #expect(SecretsRun.describeOutput(plain, robot: false) == SecretsRun.describeText(plain))
    }
}
