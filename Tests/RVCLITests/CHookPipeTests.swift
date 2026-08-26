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

        let stage = URL(fileURLWithPath: "/tmp/swift-arch-c8hook21/stage", isDirectory: true)
        let skipRelease = trioIsStaged(at: stage) ? "1" : "0"
        let isolationHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-c-hook-iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: isolationHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolationHome) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        process.environment = [
            "HOME": isolationHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
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
