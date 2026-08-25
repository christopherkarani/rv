import Foundation
import Testing

func fixtureURL(_ relativePath: String) throws -> URL {
    let testsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
    let url = testsDir
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        Issue.record("missing fixture \(relativePath) at \(url.path)")
        throw FixtureError.missing(relativePath)
    }
    return url
}

func withTempHome(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-scan-adapter-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

enum FixtureError: Error {
    case missing(String)
}
