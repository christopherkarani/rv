import Foundation
import RVDomain

/// Discovers host session roots, recognizes layout files, and surface-extracts events.
public protocol SessionStoreAdapter: Sendable {
    var host: ScanHostID { get }
    func roots(home: ScanHome) -> [URL]
    func recognizes(fileURL: URL) -> Bool
    func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent]
}
