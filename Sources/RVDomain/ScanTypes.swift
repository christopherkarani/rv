import Foundation

/// Hard caps for session-store walks (REQ-016).
public struct ScanBounds: Sendable, Equatable {
    public var maxDepth: Int
    public var maxFiles: Int
    public var maxTotalBytes: Int64
    public var maxFileBytes: Int64

    public init(
        maxDepth: Int = 8,
        maxFiles: Int = 10_000,
        maxTotalBytes: Int64 = 268_435_456,
        maxFileBytes: Int64 = 33_554_432
    ) {
        self.maxDepth = maxDepth
        self.maxFiles = maxFiles
        self.maxTotalBytes = maxTotalBytes
        self.maxFileBytes = maxFileBytes
    }

    /// REQ-016 package defaults.
    public static let `default` = ScanBounds()
}

/// Known host session-store kinds for forensics discovery.
public enum ScanHostID: String, Sendable, Equatable, Hashable {
    case claude
    case pi
    case grok
    case opencode
}

/// One surface-extracted shell candidate plus provenance.
public struct ExtractedEvent: Sendable, Equatable {
    public var host: ScanHostID
    public var sessionID: String?
    public var sourcePath: String
    public var occurredAt: Date?
    public var command: ShellCommand

    public init(
        host: ScanHostID,
        sessionID: String? = nil,
        sourcePath: String,
        occurredAt: Date? = nil,
        command: ShellCommand
    ) {
        self.host = host
        self.sessionID = sessionID
        self.sourcePath = sourcePath
        self.occurredAt = occurredAt
        self.command = command
    }
}

/// A deny finding (or dedupe group) from session forensics.
public struct ScanFinding: Sendable, Equatable {
    public var host: ScanHostID
    public var sessionID: String?
    public var sourcePath: String
    public var occurredAt: Date?
    public var ruleID: RuleID
    public var packID: PackID
    public var matchingView: MatchingView
    public var count: Int
    public var lastSeen: Date?

    public init(
        host: ScanHostID,
        sessionID: String? = nil,
        sourcePath: String,
        occurredAt: Date? = nil,
        ruleID: RuleID,
        packID: PackID,
        matchingView: MatchingView,
        count: Int = 1,
        lastSeen: Date? = nil
    ) {
        self.host = host
        self.sessionID = sessionID
        self.sourcePath = sourcePath
        self.occurredAt = occurredAt
        self.ruleID = ruleID
        self.packID = packID
        self.matchingView = matchingView
        self.count = count
        self.lastSeen = lastSeen
    }
}

public struct ScanWarning: Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ScanReport: Sendable, Equatable {
    public var findings: [ScanFinding]
    public var warnings: [ScanWarning]
    public var filesScanned: Int
    public var eventsExtracted: Int
    public var setupNudgeRecommended: Bool

    public init(
        findings: [ScanFinding] = [],
        warnings: [ScanWarning] = [],
        filesScanned: Int = 0,
        eventsExtracted: Int = 0,
        setupNudgeRecommended: Bool = false
    ) {
        self.findings = findings
        self.warnings = warnings
        self.filesScanned = filesScanned
        self.eventsExtracted = eventsExtracted
        self.setupNudgeRecommended = setupNudgeRecommended
    }
}
