import RVDomain

/// Deny report plus hosts that produced extracted events (including allows).
public struct SessionScanResult: Sendable, Equatable {
    public var report: ScanReport
    public var eventHosts: Set<ScanHostID>

    public init(report: ScanReport, eventHosts: Set<ScanHostID> = []) {
        self.report = report
        self.eventHosts = eventHosts
    }
}
