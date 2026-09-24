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

@Test func clangDeploymentTargetIsMacOS15() throws {
    let root = repoRoot()
    let paths = [
        "Scripts/release.sh",
        "Scripts/c-hook-proof.sh",
        "Scripts/host-attach-proof.sh",
        "Sources/rv-c/tests/run.sh",
    ]
    for path in paths {
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        #expect(text.contains("-mmacosx-version-min=15.0"), "\(path) must target macOS 15")
        #expect(text.contains("-mmacosx-version-min=26.0") == false, "\(path) still targets macOS 26")
    }
    let release = try String(contentsOf: root.appendingPathComponent("Scripts/release.sh"), encoding: .utf8)
    #expect(release.contains("macOS 15 Apple Silicon, or Linux aarch64/x86_64"))
    let units = try String(contentsOf: root.appendingPathComponent("Sources/rv-c/tests/run.sh"), encoding: .utf8)
    #expect(units.contains("macOS 15 Apple Silicon, or Linux aarch64/x86_64"))
    let proof = try String(contentsOf: root.appendingPathComponent("Scripts/c-hook-proof.sh"), encoding: .utf8)
    #expect(proof.contains("macOS 15 Apple Silicon, or Linux aarch64/x86_64"))
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
