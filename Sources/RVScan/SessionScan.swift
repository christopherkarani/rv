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

/// Injected clock and scan inputs. The scan core must not read the wall clock.
public struct SessionScanRequest: Sendable, Equatable {
    public var home: ScanHome
    public var now: Date
    public var rootPath: String?
    public var includeGlobs: [String]
    public var hostFilter: ScanHostID?
    /// Inclusive lookback in days relative to `now`. Ignored when `scanAll` is true.
    public var days: UInt
    /// `--all`: skip the time window. Bounds still apply.
    public var scanAll: Bool
    public var packIDs: [PackID]
    public var allEvents: Bool
    public var bounds: ScanBounds

    public var timeWindow: ScanTimeWindow {
        scanAll ? .all : ScanTimeWindow(dayCount: days)
    }

    public init(
        home: ScanHome,
        now: Date,
        rootPath: String? = nil,
        includeGlobs: [String] = [],
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
        self.includeGlobs = includeGlobs
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
    case includeGlobRequiresPath
    case packsUnavailable
}

/// Session-forensics entry: walk, extract, classify, time-window, dedupe.
public struct SessionScan: Sendable {
    public init() {}

    public func run(
        _ request: SessionScanRequest,
        fileManager: FileManager = .default
    ) throws -> SessionScanResult {
        if request.includeGlobs.isEmpty == false, request.rootPath == nil {
            throw SessionScanError.includeGlobRequiresPath
        }

        let selected = SessionScanAdapters.selected(hostFilter: request.hostFilter)
        let walker = DirectoryWalker(bounds: request.bounds)
        var warnings: [ScanWarning] = []
        var candidates: [(url: URL, adapter: any SessionStoreAdapter)] = []
        var filesScanned = 0

        if let rootPath = request.rootPath {
            let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw SessionScanError.pathNotFound(rootPath)
            }
            let walk = try walkMapped(walker: walker, root: root, fileManager: fileManager)
            warnings.append(contentsOf: walk.warnings)
            filesScanned = walk.filesVisited
            for fileURL in walk.fileURLs {
                let recognized = selected.filter { $0.recognizes(fileURL: fileURL) }
                if recognized.isEmpty {
                    if matchesIncludeGlob(
                        fileURL: fileURL,
                        scanRoot: root,
                        patterns: request.includeGlobs
                    ) {
                        for adapter in selected {
                            candidates.append((fileURL, adapter))
                        }
                    }
                    continue
                }
                for adapter in recognized {
                    candidates.append((fileURL, adapter))
                }
            }
        } else {
            for adapter in selected {
                for root in adapter.roots(home: request.home) {
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                          isDirectory.boolValue
                    else {
                        continue
                    }
                    let walk = try walkMapped(walker: walker, root: root, fileManager: fileManager)
                    warnings.append(contentsOf: walk.warnings)
                    filesScanned += walk.filesVisited
                    for fileURL in walk.fileURLs {
                        guard adapter.recognizes(fileURL: fileURL) else { continue }
                        candidates.append((fileURL, adapter))
                    }
                }
            }
        }

        var events: [ExtractedEvent] = []
        events.reserveCapacity(candidates.count)
        for candidate in candidates {
            let data = (try? Data(contentsOf: candidate.url)) ?? Data()
            events.append(
                contentsOf: try candidate.adapter.extract(fileURL: candidate.url, data: data)
            )
        }

        let classify: ScanClassify
        do {
            classify = try ScanClassify(enabledPacks: request.packIDs)
        } catch ScanClassifyError.packsUnavailable {
            throw SessionScanError.packsUnavailable
        }
        let resolver = fileInstantResolver()
        let rawFindings = classify.classify(events)
        let inWindow = request.timeWindow.filter(rawFindings, now: request.now, resolver: resolver)
        let findings = ScanDedupe.apply(inWindow, allEvents: request.allEvents, resolver: resolver)

        return SessionScanResult(
            report: ScanReport(
                findings: findings,
                warnings: warnings,
                filesScanned: filesScanned,
                eventsExtracted: events.count
            ),
            eventHosts: Set(events.map(\.host))
        )
    }
}

private func walkMapped(
    walker: DirectoryWalker,
    root: URL,
    fileManager: FileManager
) throws -> DirectoryWalkResult {
    do {
        return try walker.walk(root: root, fileManager: fileManager)
    } catch DirectoryWalkError.listingFailed(let path) {
        throw SessionScanError.listingFailed(path)
    }
}

private func fileInstantResolver() -> ScanFindingInstantResolver {
    ScanFindingInstantResolver { path in
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}
