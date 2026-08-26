import Foundation
import RVDomain

/// A deny finding (or later dedupe group) from session forensics.
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

/// Deny findings plus walk/extract counters. Setup nudge is CLI-only (T9).
public struct ScanReport: Sendable, Equatable {
    public var findings: [ScanFinding]
    public var warnings: [ScanWarning]
    public var filesScanned: Int
    public var eventsExtracted: Int

    public init(
        findings: [ScanFinding] = [],
        warnings: [ScanWarning] = [],
        filesScanned: Int = 0,
        eventsExtracted: Int = 0
    ) {
        self.findings = findings
        self.warnings = warnings
        self.filesScanned = filesScanned
        self.eventsExtracted = eventsExtracted
    }
}

/// Injected clock and scan inputs. The scan core must not call `Date()`.
public struct SessionScanRequest: Sendable, Equatable {
    public var home: ScanHome
    public var now: Date
    public var rootPath: String?
    public var hostFilter: ScanHostID?
    /// Inclusive lookback in days relative to `now`. Ignored when `scanAll` is true.
    public var days: UInt
    /// `--all`: skip the time window. Bounds still apply.
    public var scanAll: Bool
    public var packIDs: [PackID]
    public var allEvents: Bool
    public var bounds: ScanBounds

    public init(
        home: ScanHome,
        now: Date,
        rootPath: String? = nil,
        hostFilter: ScanHostID? = nil,
        days: UInt = 7,
        scanAll: Bool = false,
        packIDs: [PackID] = dayOnePackIDs,
        allEvents: Bool = false,
        bounds: ScanBounds = .default
    ) {
        self.home = home
        self.now = now
        self.rootPath = rootPath
        self.hostFilter = hostFilter
        self.days = days
        self.scanAll = scanAll
        self.packIDs = packIDs
        self.allEvents = allEvents
        self.bounds = bounds
    }
}

public enum SessionScanError: Error, Sendable, Equatable {
    case missingRoot
    case pathNotFound(String)
    case listingFailed(String)
}

/// Session-forensics entry. Extract/classify/dedupe land in later tickets.
public struct SessionScan: Sendable {
    public init() {}

    public func run(
        _ request: SessionScanRequest,
        fileManager: FileManager = .default
    ) throws -> ScanReport {
        guard let rootPath = request.rootPath else {
            throw SessionScanError.missingRoot
        }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw SessionScanError.pathNotFound(rootPath)
        }

        let walk: DirectoryWalkResult
        do {
            walk = try DirectoryWalker(bounds: request.bounds).walk(root: root, fileManager: fileManager)
        } catch DirectoryWalkError.listingFailed(let path) {
            throw SessionScanError.listingFailed(path)
        }
        return ScanReport(
            findings: [],
            warnings: walk.warnings,
            filesScanned: walk.filesVisited,
            eventsExtracted: 0
        )
    }
}
