#if os(macOS)
import Foundation
import Testing
import RVTheme
@testable import RVCLI

@Suite(.serialized)
struct CHookPipeTests {
    @Test func cHookProof_stagedBinariesAndTempHome() throws {
        let root = repoRootURL()
        let script = root.appendingPathComponent("tools/c-hook-proof.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))

        let stage = root.appendingPathComponent(".build/c-hook-stage", isDirectory: true)
        let skipRelease = trioIsStaged(at: stage) ? "1" : "0"
        let isolationHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-c-hook-iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: isolationHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolationHome) }
        try exposePinnedToolchain(in: isolationHome, repoRoot: root)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        process.environment = [
            "HOME": isolationHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            // launchd cannot read plists under Darwin TMPDIR (/var/folders/...).
            "TMPDIR": "/tmp",
            "RV_RELEASE_STAGE": stage.path,
            "RV_C_HOOK_SKIP_RELEASE": skipRelease,
            "TERM": "dumb",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "c-hook-proof failed:\n\(err)\n\(out)")
        #expect(out.contains("AC-001 ok"))
        #expect(out.contains("AC-002 ok"))
        #expect(out.contains("AC-003 ok"))
        #expect(out.contains("AC-004 ok"))
        #expect(out.contains("AC-005 ok"))
        #expect(out.contains("REQ-004 ok"))
        #expect(out.contains("AC-006 ok"))
        #expect(out.contains("AC-011 ok"))
        #expect(out.contains("AC-011-miss ok"))
        #expect(out.contains("AC-012 ok"))

        try proveHelpDispatch(stage: stage)
    }
}

private func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

/// Darwin `tools/swift-6.3.3` looks up the pin under `$HOME`. Isolation HOME
/// must still see the login toolchain so skip-release-off can run release.sh.
private func exposePinnedToolchain(in isolationHome: URL, repoRoot: URL) throws {
    guard let loginHome = ProcessInfo.processInfo.environment["HOME"], loginHome.isEmpty == false else {
        return
    }
    let pin = try String(contentsOf: repoRoot.appendingPathComponent(".swift-version"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard pin.isEmpty == false else { return }
    let name = "swift-\(pin)-RELEASE.xctoolchain"
    let src = URL(fileURLWithPath: loginHome, isDirectory: true)
        .appendingPathComponent("Library/Developer/Toolchains/\(name)", isDirectory: true)
    guard FileManager.default.fileExists(atPath: src.path) else { return }
    let destDir = isolationHome.appendingPathComponent("Library/Developer/Toolchains", isDirectory: true)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: destDir.appendingPathComponent(name, isDirectory: true),
        withDestinationURL: src
    )
}

private func trioIsStaged(at stage: URL) -> Bool {
    let fm = FileManager.default
    guard
        fm.isExecutableFile(atPath: stage.appendingPathComponent("rv").path),
        fm.isExecutableFile(atPath: stage.appendingPathComponent("rv-cli").path),
        fm.isExecutableFile(atPath: stage.appendingPathComponent("rvd").path)
    else {
        return false
    }
    let bundles = (try? fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)) ?? []
    return bundles.contains { $0.lastPathComponent.hasSuffix("_RVPacks.bundle") }
}

private func proveHelpDispatch(stage: URL) throws {
    let rv = stage.appendingPathComponent("rv")
    try #require(FileManager.default.isExecutableFile(atPath: rv.path))
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-c-hook-help-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let process = Process()
    process.executableURL = rv
    process.arguments = ["hook", "--help"]
    process.environment = [
        "HOME": home.path,
        "PATH": "/usr/bin:/bin",
        "TERM": "dumb",
    ]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let text = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0)
    #expect(text == HelpDispatch.text(.hook, palette: colorOffPalette))
    #expect(text.contains("OVERVIEW:") == false)
    #expect(text.contains("SUBCOMMANDS:") == false)
}
#endif
