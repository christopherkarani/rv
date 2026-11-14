import Testing
import RVDomain
import RVPolicy

/// Owner-set `allowed_ips` in the network scope of a policy diff: a new
/// private range is a loosening the report names, a range already
/// reviewed is not, and an entry rv would refuse blocks.
struct PolicyDiffRiskAllowedIPsTests {
    private func report(old: [String: [String]] = [:], new: [String: [String]]) -> PolicyDiffRiskReport {
        PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(),
            newDocument: PolicyDocument(),
            oldScope: PolicyNetworkScope(allowedIPs: old),
            newScope: PolicyNetworkScope(allowedIPs: new)
        )
    }

    @Test func newPrivateRangeIsReportedAsALoosening() {
        let report = report(new: ["staging.corp.lan": ["10.0.5.0/24"]])
        #expect(
            report.findings == [
                PolicyDiffRiskFinding(
                    kind: .privateRangeAllowed, severity: .advisory, detail: "staging.corp.lan 10.0.5.0/24")
            ])
        #expect(report.previewLines == ["risk: 0 blocking, 1 advisory", "  [advisory] private-range-allowed staging.corp.lan 10.0.5.0/24"])
    }

    /// Reviewed ranges are not re-flagged, whatever their spelling; moving
    /// a range to another host is a new grant for that host.
    @Test func reviewedRangesAreNotReflagged() {
        #expect(report(old: ["db.corp.lan": ["10.0.5.0/24"]], new: ["DB.corp.lan": ["::ffff:10.0.5.0/120"]]).findings.isEmpty)
        let moved = report(old: ["db.corp.lan": ["10.0.5.0/24"]], new: ["cache.corp.lan": ["10.0.5.0/24"]])
        #expect(moved.findings.map(\.detail) == ["cache.corp.lan 10.0.5.0/24"])
        #expect(report(old: ["db.corp.lan": ["10.0.5.0/24"]], new: [:]).findings.isEmpty)
    }

    @Test func forbiddenAndMalformedRangesBlock() {
        let forbidden = report(new: ["db.corp.lan": ["169.254.169.254"]])
        #expect(forbidden.hasBlockingFindings)
        #expect(forbidden.findings.map(\.kind) == [.sensitiveRange])
        let malformed = report(new: ["db.corp.lan": ["10.0.5.0/33"]])
        #expect(malformed.hasBlockingFindings)
        #expect(malformed.findings.map(\.kind) == [.unparseableDestination])
    }
}
