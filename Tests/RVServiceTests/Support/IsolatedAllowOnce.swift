import Foundation
import RVDomain
import RVPolicy
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
    log: (any ServiceLog)? = nil,
    home: HomeDirectory? = nil,
    onActivity: (@Sendable () async -> Void)? = nil
) throws -> ServiceRuntime {
    let resolvedHome = try home
        ?? HomeDirectory(validating: isolatedHomeDirectory().path)
    return ServiceRuntime(
        snapshots: snapshots,
        home: resolvedHome,
        allowOnceDirectory: try isolatedAllowOnceDirectory(),
        log: log,
        onActivity: onActivity
    )
}
