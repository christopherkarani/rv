import Foundation
import Testing
import RVHistory
@testable import RVCLI

/// SEC-002: agent-influenced text in egress and audit-verify output renders escaped.
struct UntrustedTextEscapeTests {
    private static let hostile = "evil\u{1b}]52;x\u{7}\u{202e}.example.com"
    private static let asciiOnly = "a.example.com"

    private func proposal(host: String, reason: String) -> EgressProposalView {
        EgressProposalView(
            id: "id-1", host: host, port: 443, state: "awaiting-human", reason: reason,
            createdAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 60))
    }

    private func denial(host: String, reason: String) -> EgressDenialView {
        EgressDenialView(host: host, port: 443, reason: reason, recordedAt: Date(timeIntervalSince1970: 0))
    }

    private func expectClean(_ text: String) {
        #expect(text.contains("\u{1b}") == false)
        #expect(text.contains("\u{7}") == false)
        #expect(text.contains("\u{202e}") == false)
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

    @Test func plainASCIIRobotBytesUnchanged() throws {
        let view = proposal(host: Self.asciiOnly, reason: "no rule")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        #expect(try EgressReviewRun.robot([view]) == String(decoding: try encoder.encode([view]), as: UTF8.self))
        let denials = [denial(host: Self.asciiOnly, reason: "no rule")]
        #expect(try EgressReviewRun.robotDenials(denials) == String(decoding: try encoder.encode(denials), as: UTF8.self))
    }

    @Test func auditVerifyEscapes() {
        let broken = AuditChainReport(
            lines: 2, unchained: 0, head: "h",
            firstBreak: .init(line: 2, reason: "bad \(Self.hostile)"))
        expectClean(AuditVerifyRun.json(broken))
        expectClean(AuditVerifyRun.text(broken, path: "/tmp/\(Self.hostile)"))
    }

    @Test func auditVerifyPlainASCIIUnchanged() {
        let ok = AuditChainReport(lines: 1, unchained: 0, head: "abc", firstBreak: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        #expect(AuditVerifyRun.json(ok) == String(decoding: try! encoder.encode(ok), as: UTF8.self) + "\n")
    }
}
