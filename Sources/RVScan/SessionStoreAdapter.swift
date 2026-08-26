import Foundation
import RVDomain

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

/// Discovers host session roots, recognizes layout files, and surface-extracts events.
public protocol SessionStoreAdapter: Sendable {
    var host: ScanHostID { get }
    func roots(home: ScanHome) -> [URL]
    func recognizes(fileURL: URL) -> Bool
    func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent]
}
