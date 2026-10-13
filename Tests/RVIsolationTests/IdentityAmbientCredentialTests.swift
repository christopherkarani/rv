#if os(macOS)
import Darwin
import Foundation
import RVDomain
import RVPolicy
import Testing
@testable import RVIsolation

@Suite(.serialized)
struct IdentityAmbientCredentialTests {
    /// A real contained child records only whether the unrelated dummy
    /// credential was readable. Neither stdout nor the marker carries its body.
    @Test func customLaunchCannotReadAmbientCodexAuthentication() throws {
        let name = "customLaunchCannotReadAmbientCodexAuthentication"
        guard ProcessInfo.processInfo.environment["RV_AMBIENT_PROBE"] == name else {
            try runIsolatedAmbientProbe(name)
            return
        }
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let fixture = try AmbientCodexFixture(root: tree.rootURL)
        defer { fixture.restore() }
        try #require(ProcessInfo.processInfo.environment["HOME"] == fixture.home.path)
        // M4: custom preparation measures the executable against the
        // authorized digest; the fixture authorizes the real bytes.
        let shDigest = try #require(RVFileDigest.sha256HexOfFile(atPath: "/bin/sh"))
        let selection = try AgentLaunchSelection.resolveCustom(
            executable: "/bin/sh", expectedContentDigestSHA256: shDigest
        ).get()
        let supervisor = try WorkspaceSessionSupervisor.open(
            try #require(WorkingDirectory(validating: tree.workspaceURL.path)),
            lifecycleLog: .file(tree.rootURL.appendingPathComponent("workspace.jsonl")),
            runtimeLog: tree.rootURL.appendingPathComponent("runtime.jsonl"),
            instanceJournal: .file(tree.rootURL.appendingPathComponent("instances.jsonl"))
        ).get()
        defer { _ = supervisor.close() }
        // Fixture paths contain no quotes. The digest authorizes the
        // measured fixture bytes; preparation and spawn commit verify it.
        let script = "if /bin/cat '\(fixture.authentication.path)' >/dev/null 2>&1; then "
            + "printf readable > ambient-read-result; else printf denied > ambient-read-result; fi; /bin/sleep 10"
        let runtime = try supervisor.launchAgent(
            selection: selection, arguments: ["-c", script],
            io: .discard, admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("runtime.jsonl")),
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let result = tree.workspaceURL.appendingPathComponent("ambient-read-result")
        let deadline = Date().addingTimeInterval(8)
        while (try? String(contentsOf: result, encoding: .utf8))?.isEmpty != false,
            Date() < deadline {
            usleep(10_000)
        }
        let readOutcome = try String(contentsOf: result, encoding: .utf8)
        #expect(readOutcome == "denied")
        try supervisor.cancel(runtime.id).get()
        try recordAmbientProbeCompletion()
    }

    /// The production prepare oracle for an explicit custom executable must
    /// omit unrelated provider credentials from the host's installed bin set.
    /// This checks the generated OS policy, not credential read success.
    @Test func customPreparationDoesNotGrantAmbientCodexAuthentication() throws {
        let name = "customPreparationDoesNotGrantAmbientCodexAuthentication"
        guard ProcessInfo.processInfo.environment["RV_AMBIENT_PROBE"] == name else {
            try runIsolatedAmbientProbe(name)
            return
        }
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let fixture = try AmbientCodexFixture(root: tree.rootURL)
        defer { fixture.restore() }
        try #require(ProcessInfo.processInfo.environment["HOME"] == fixture.home.path)
        let command = try #require(IsolatedCommand(
            executable: "/bin/cat", arguments: [fixture.authentication.path]
        ))
        let request = try prepareSeatbelt(tree.contained, command, legacyAgentIntegration: false).get()
        #expect(request.legacyAgentIntegration == false)
        #expect(request.withIO(.pseudoTerminal(rows: 24, columns: 80)).legacyAgentIntegration == false)
        let profile = try #require(request.seatbeltProfile)
        // Prove the fixture actually activates the pre-fix ambient branch.
        let resolution = AgentBin.resolve(binDirectory: fixture.binDirectory, home: fixture.home.path)
        #expect(resolution.credentials.contains(fixture.authentication.path))
        #expect(profile.source.contains("(literal \"\(fixture.authentication.path)\")") == false)
        try recordAmbientProbeCompletion()
    }
}

private struct AmbientCodexFixture {
    let home: URL
    let authentication: URL
    let binDirectory: String
    let link: String
    let previousHome: String?
    let createdDirectory: Bool

    init(root: URL) throws {
        let manager = FileManager.default
        home = root.appendingPathComponent("isolated-operator-home", isDirectory: true)
        authentication = home.appendingPathComponent(".codex/auth.json")
        try manager.createDirectory(at: authentication.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Deliberately dummy content. Never inspect the user's actual credentials.
        try Data("{\"fixture\":\"not-a-secret\"}".utf8).write(to: authentication)
        binDirectory = try #require(AgentBin.directory())
        let isolatedRoot = try #require(ProcessInfo.processInfo.environment["RV_AMBIENT_PROBE_ROOT"])
        try #require(binDirectory.hasPrefix(isolatedRoot + "/"),
            "The helper must own its private installed-bin directory")
        link = binDirectory + "/codex"
        var linkStatus = stat()
        // Refuse collisions, including dangling symlinks; never replace an
        // installed provider executable to make this test pass.
        try #require(lstat(link, &linkStatus) != 0 && errno == ENOENT,
            "Ambient credential fixture requires an unused installed codex link")
        var directoryStatus = stat()
        createdDirectory = lstat(binDirectory, &directoryStatus) != 0
        if createdDirectory {
            try manager.createDirectory(atPath: binDirectory, withIntermediateDirectories: true)
        }
        do {
            try manager.createSymbolicLink(atPath: link, withDestinationPath: "/usr/bin/true")
        } catch {
            if createdDirectory { _ = rmdir(binDirectory) }
            throw error
        }
        previousHome = getenv("HOME").map { String(cString: $0) }
        if setenv("HOME", home.path, 1) != 0 {
            try? manager.removeItem(atPath: link)
            if createdDirectory { _ = rmdir(binDirectory) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func restore() {
        if let previousHome {
            setenv("HOME", previousHome, 1)
        } else {
            unsetenv("HOME")
        }
        try? FileManager.default.removeItem(atPath: link)
        if createdDirectory {
            // rmdir removes only an empty directory; another test's new file
            // must survive even if it arrived while this fixture was running.
            _ = rmdir(binDirectory)
        }
    }
}

private final class AmbientProbeBundleMarker: NSObject {}

/// Launch only this test in a copied SwiftPM helper. The copy makes
/// AgentBin.directory() private too; neither HOME nor the installed bin of the
/// parent test process changes. No nested `swift test` or build lock is used.
private func runIsolatedAmbientProbe(_ name: String) throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("rv-ambient-helper-\(UUID())")
        .resolvingSymlinksInPath()
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let locate = Process()
    let located = Pipe()
    locate.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    locate.arguments = ["swift"]
    locate.standardOutput = located
    locate.standardError = FileHandle.nullDevice
    try locate.run()
    let pathData = located.fileHandleForReading.readDataToEndOfFile()
    locate.waitUntilExit()
    try #require(locate.terminationStatus == 0)
    let swiftPath = String(decoding: pathData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let toolchain = URL(fileURLWithPath: swiftPath).deletingLastPathComponent().deletingLastPathComponent()
    let helperSource = toolchain.appendingPathComponent("libexec/swift/pm/swiftpm-testing-helper")
    let helper = root.appendingPathComponent("swiftpm-testing-helper")
    try manager.copyItem(at: helperSource, to: helper)
    let bundle = Bundle(for: AmbientProbeBundleMarker.self).bundleURL
    try #require(bundle.pathExtension == "xctest")
    let testLibrary = bundle.appendingPathComponent("Contents/MacOS/\(bundle.deletingPathExtension().lastPathComponent)")
    let receipt = root.appendingPathComponent("probe-completed")
    let log = root.appendingPathComponent("helper-output")
    try Data().write(to: log)
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = helper
    process.arguments = ["--test-bundle-path", testLibrary.path, "--testing-library", "swift-testing",
        "--filter", "IdentityAmbientCredentialTests/\(name)"]
    var environment = ProcessInfo.processInfo.environment
    environment["RV_AMBIENT_PROBE"] = name
    environment["RV_AMBIENT_PROBE_ROOT"] = root.path
    environment["RV_AMBIENT_PROBE_RECEIPT"] = receipt.path
    process.environment = environment
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let deadline = Date().addingTimeInterval(45)
    while process.isRunning, Date() < deadline { usleep(10_000) }
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
    let diagnostics = try String(contentsOf: log, encoding: .utf8)
    #expect(process.terminationStatus == 0, "Isolated probe failed: \(diagnostics)")
    #expect(manager.fileExists(atPath: receipt.path), "Filtered probe did not complete: \(diagnostics)")
}

private func recordAmbientProbeCompletion() throws {
    let path = try #require(ProcessInfo.processInfo.environment["RV_AMBIENT_PROBE_RECEIPT"])
    try Data("completed".utf8).write(to: URL(fileURLWithPath: path))
}
#endif
