import Foundation
import Testing

@Test func packageDeclaresMacOS15() throws {
    let package = try String(contentsOf: repoRoot().appendingPathComponent("Package.swift"), encoding: .utf8)
    #expect(package.contains(".macOS(.v15)"))
    #expect(package.contains(".macOS(.v26)") == false)
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
