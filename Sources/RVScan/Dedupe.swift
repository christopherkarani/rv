import Foundation
import RVDomain

/// Dedupe identity: matching view + rule (REQ-010).
public struct ScanDedupeKey: Hashable, Sendable, Equatable {
    public let matchingView: MatchingView
    public let ruleID: RuleID

    public init(matchingView: MatchingView, ruleID: RuleID) {
        self.matchingView = matchingView
        self.ruleID = ruleID
    }

    public init(finding: ScanFinding) {
        matchingView = finding.matchingView
        ruleID = finding.ruleID
    }
}

public enum ScanDedupe {
    /// Groups findings that share a matching view and rule, keeping the latest.
    ///
    /// - Parameter reportsEveryEvent: When true, returns `findings` unchanged.
    public static func grouped(
        _ findings: [ScanFinding],
        reportsEveryEvent: Bool = false,
        resolver: ScanFindingInstantResolver = ScanFindingInstantResolver()
    ) -> [ScanFinding] {
        guard reportsEveryEvent == false else { return findings }

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
            matchingView: latest.matchingView,
            count: count,
            lastSeen: lastSeen
        )
    }
}
