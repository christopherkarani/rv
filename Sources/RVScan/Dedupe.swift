import Foundation
import RVDomain

/// Dedupe identity: matching view + `rule_id` colon form (REQ-010).
public struct ScanDedupeKey: Hashable, Sendable, Equatable {
    public let matchingView: String
    public let ruleID: String

    public init(matchingView: MatchingView, ruleID: RuleID) {
        self.matchingView = matchingView.rawValue
        self.ruleID = ruleID.rawValue
    }

    public init(finding: ScanFinding) {
        matchingView = finding.matchingView.rawValue
        ruleID = finding.ruleID.rawValue
    }
}

public enum ScanDedupe {
    public static func apply(
        _ findings: [ScanFinding],
        allEvents: Bool = false,
        resolver: ScanFindingInstantResolver = ScanFindingInstantResolver()
    ) -> [ScanFinding] {
        guard allEvents == false else { return findings }

        var groups: [ScanDedupeKey: [ScanFinding]] = [:]
        for finding in findings {
            groups[ScanDedupeKey(finding: finding), default: []].append(finding)
        }

        return groups.values.map { group in
            merge(group, resolver: resolver)
        }
        .sorted { lhs, rhs in
            let left = resolver.instant(for: lhs) ?? .distantPast
            let right = resolver.instant(for: rhs) ?? .distantPast
            return left > right
        }
    }

    private static func merge(
        _ group: [ScanFinding],
        resolver: ScanFindingInstantResolver
    ) -> ScanFinding {
        let latest = group.max { lhs, rhs in
            let left = resolver.instant(for: lhs) ?? .distantPast
            let right = resolver.instant(for: rhs) ?? .distantPast
            return left < right
        } ?? group[0]

        let count = group.reduce(0) { $0 + $1.count }
        let lastSeen = group.compactMap { resolver.instant(for: $0) }.max()

        return ScanFinding(
            host: latest.host,
            sessionID: latest.sessionID,
            sourcePath: latest.sourcePath,
            occurredAt: latest.occurredAt,
            ruleID: latest.ruleID,
            packID: latest.packID,
            matchingView: latest.matchingView,
            count: count,
            lastSeen: lastSeen
        )
    }
}
