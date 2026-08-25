import Foundation
import RVDomain

/// Default session-scan time filter (REQ-004). `--all` sets `isDisabled`.
public struct ScanTimeWindow: Sendable, Equatable {
    public static let defaultDayCount: UInt = 7

    public var dayCount: UInt
    public var isDisabled: Bool

    public init(dayCount: UInt = ScanTimeWindow.defaultDayCount, isDisabled: Bool = false) {
        self.dayCount = dayCount
        self.isDisabled = isDisabled
    }

    public static let `default` = ScanTimeWindow()
    public static let all = ScanTimeWindow(isDisabled: true)
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
        guard isDisabled == false else { return findings }
        let cutoff = now.addingTimeInterval(-TimeInterval(dayCount) * 86_400)
        return findings.filter { finding in
            guard let instant = resolver.instant(for: finding) else { return false }
            return instant >= cutoff
        }
    }
}
