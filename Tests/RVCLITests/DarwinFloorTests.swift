import Foundation
import Testing

@Test func packageDeclaresMacOS15() throws {
    let package = try String(contentsOf: repoRoot().appendingPathComponent("Package.swift"), encoding: .utf8)
    #expect(package.contains(".macOS(.v15)"))
    #expect(package.contains(".macOS(.v26)") == false)
}

@Test func installScriptRequiresMacOS15() throws {
    let install = try String(contentsOf: repoRoot().appendingPathComponent("install.sh"), encoding: .utf8)
    #expect(install.contains("[ \"$major\" -ge 15 ]"))
    #expect(install.contains("[ \"$major\" -ge 26 ]") == false)
    #expect(install.contains("macOS 15 Apple Silicon, or Linux aarch64/x86_64"))
    #expect(install.contains("macOS 26 Apple Silicon") == false)
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
