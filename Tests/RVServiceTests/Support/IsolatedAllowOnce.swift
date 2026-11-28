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
    // The judge decides in these homes (`judge.mode` unset is shadow).
    let config = root.appendingPathComponent(".config/rv", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try Data(#"{"judge":{"mode":"live"}}"#.utf8).write(to: config.appendingPathComponent("config.json"))
    return root
}

func isolatedRuntime(
    snapshots: [PackSnapshot]? = nil,
    log: (any ServiceLog)? = nil,
    home: HomeDirectory? = nil
) throws -> ServiceRuntime {
    let resolvedHome = try home
        ?? HomeDirectory(validating: isolatedHomeDirectory().path)
    return hookTestRuntime(
        snapshots: snapshots,
        home: resolvedHome,
        allowOnceDirectory: try isolatedAllowOnceDirectory(),
        log: log
    )
}
