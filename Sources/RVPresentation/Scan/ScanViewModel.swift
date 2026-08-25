import Foundation
import RVDomain

/// One deny finding row for pretty and browse surfaces.
public struct ScanFindingRow: Equatable, Sendable {
    public var host: ScanHostID
    public var sessionID: String?
    public var sourcePath: String
    public var occurredAt: Date?
    public var ruleID: RuleID
    public var packID: PackID
    public var commandDisplay: String
    public var count: Int
    public var lastSeen: Date?

    public var ruleLabel: String { ruleID.rawValue }

    public init(
        host: ScanHostID,
        sessionID: String? = nil,
        sourcePath: String,
        occurredAt: Date? = nil,
        ruleID: RuleID,
        packID: PackID,
        commandDisplay: String,
        count: Int = 1,
        lastSeen: Date? = nil
    ) {
        self.host = host
        self.sessionID = sessionID
        self.sourcePath = sourcePath
        self.occurredAt = occurredAt
        self.ruleID = ruleID
        self.packID = packID
        self.commandDisplay = commandDisplay
        self.count = count
        self.lastSeen = lastSeen
    }
}

/// Read-only scan report projection for human frames.
public struct ScanViewModel: Equatable, Sendable {
    public var rows: [ScanFindingRow]
    public var warnings: [ScanWarning]
    public var filesScanned: Int
    public var eventsExtracted: Int
    public var setupNudgeRecommended: Bool
    public var showCommand: Bool

    public init(
        rows: [ScanFindingRow],
        warnings: [ScanWarning] = [],
        filesScanned: Int = 0,
        eventsExtracted: Int = 0,
        setupNudgeRecommended: Bool = false,
        showCommand: Bool = false
    ) {
        self.rows = rows
        self.warnings = warnings
        self.filesScanned = filesScanned
        self.eventsExtracted = eventsExtracted
        self.setupNudgeRecommended = setupNudgeRecommended
        self.showCommand = showCommand
    }
}

public func scanFindingRow(
    from finding: ScanFinding,
    showCommand: Bool
) -> ScanFindingRow {
    let commandDisplay = showCommand
        ? finding.matchingView.rawValue
        : redactMatchingView(finding.matchingView)
    return ScanFindingRow(
        host: finding.host,
        sessionID: finding.sessionID,
        sourcePath: finding.sourcePath,
        occurredAt: finding.occurredAt,
        ruleID: finding.ruleID,
        packID: finding.packID,
        commandDisplay: commandDisplay,
        count: finding.count,
        lastSeen: finding.lastSeen
    )
}

public func scanViewModel(
    from report: ScanReport,
    showCommand: Bool = false
) -> ScanViewModel {
    ScanViewModel(
        rows: report.findings.map { scanFindingRow(from: $0, showCommand: showCommand) },
        warnings: report.warnings,
        filesScanned: report.filesScanned,
        eventsExtracted: report.eventsExtracted,
        setupNudgeRecommended: report.setupNudgeRecommended,
        showCommand: showCommand
    )
}
