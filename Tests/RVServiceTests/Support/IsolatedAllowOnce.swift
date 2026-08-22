import Foundation
import RVDomain
@testable import RVService

func isolatedAllowOnceDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-service-allow-once-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func isolatedHomeDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-service-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func isolatedRuntime(
    snapshots: [PackSnapshot]? = nil,
    log: (any ServiceLog)? = nil
) throws -> ServiceRuntime {
    ServiceRuntime(
        snapshots: snapshots,
        home: try isolatedHomeDirectory().path,
        allowOnceDirectory: try isolatedAllowOnceDirectory(),
        log: log
    )
}
