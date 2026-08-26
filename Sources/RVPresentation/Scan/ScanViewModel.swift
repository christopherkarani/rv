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

/// One walk/extract warning for pretty and browse surfaces.
public struct ScanWarningRow: Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Read-only scan report projection for human frames.
/// CLI maps findings into this type and passes `setupNudgeRecommended`.
public struct ScanViewModel: Equatable, Sendable {
    public var rows: [ScanFindingRow]
    public var warnings: [ScanWarningRow]
    public var filesScanned: Int
    public var eventsExtracted: Int
    public var setupNudgeRecommended: Bool
    public var showCommand: Bool

    public init(
        rows: [ScanFindingRow],
        warnings: [ScanWarningRow] = [],
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

/// Projects Domain scan fields plus a matching view into a finding row.
public func scanFindingRow(
    host: ScanHostID,
    sessionID: String? = nil,
    sourcePath: String,
    occurredAt: Date? = nil,
    ruleID: RuleID,
    packID: PackID,
    matchingView: MatchingView,
    count: Int = 1,
    lastSeen: Date? = nil,
    showCommand: Bool
) -> ScanFindingRow {
    let commandDisplay = showCommand
        ? matchingView.rawValue
        : redactMatchingView(matchingView)
    return ScanFindingRow(
        host: host,
        sessionID: sessionID,
        sourcePath: sourcePath,
        occurredAt: occurredAt,
        ruleID: ruleID,
        packID: packID,
        commandDisplay: commandDisplay,
        count: count,
        lastSeen: lastSeen
    )
}
