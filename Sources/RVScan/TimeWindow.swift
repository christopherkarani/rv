import Foundation
import RVDomain

/// Default session-scan time filter (REQ-004). `.all` skips the lookback.
public enum ScanTimeWindow: Sendable, Equatable {
    case lastDays(UInt)
    case all

    public static let defaultDayCount: UInt = 7
    public static let `default` = lastDays(defaultDayCount)
}

/// Resolves a finding's instant for time-window checks. Nil `occurredAt` falls back to file mtime.
public struct ScanFindingInstantResolver: Sendable {
    public var fileModificationTime: @Sendable (String) -> Date?

    public init(fileModificationTime: @escaping @Sendable (String) -> Date? = { _ in nil }) {
        self.fileModificationTime = fileModificationTime
    }

    public func instant(for finding: ScanFinding) -> Date? {
        finding.lastSeen ?? finding.occurredAt ?? fileModificationTime(finding.sourcePath)
    }
}

extension ScanTimeWindow {
    public func filter(
        _ findings: [ScanFinding],
        now: Date,
        resolver: ScanFindingInstantResolver = ScanFindingInstantResolver()
    ) -> [ScanFinding] {
        switch self {
        case .all:
            return findings
        case .lastDays(let dayCount):
            let cutoff = now.addingTimeInterval(-TimeInterval(dayCount) * 86_400)
            return findings.filter { finding in
                guard let instant = resolver.instant(for: finding) else { return false }
                return instant >= cutoff
            }
        }
    }
}
