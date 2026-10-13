import Foundation
import Testing

private func fingerprint(_ directory: URL, ignoring: [String] = []) throws -> String {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Scripts/config-dir-fingerprint.py")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", script.path, directory.path] + ignoring.flatMap { ["--ignore", $0] }
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    return String(decoding: data, as: UTF8.self)
}

@Suite("config-dir-fingerprint.py")
struct ConfigFingerprintScriptTests {
    let root: URL
    let config: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-fingerprint-\(UUID().uuidString)", isDirectory: true)
        config = root.appendingPathComponent("rv", isDirectory: true)
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = config.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    @Test func missingOrIgnoredOnlyDirectoryIsNoneAndAFileIsAChange() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try fingerprint(config) == "(none)\n")
        try write("workspaces/ws-1/tmp/x", "x\n")
        #expect(try fingerprint(config, ignoring: ["workspaces"]) == "(none)\n")
        try write("secrets.json", "{}\n")
        #expect(try fingerprint(config, ignoring: ["workspaces"]) != "(none)\n")
    }

    @Test func contentModeAndNewFilesChangeTheFingerprint() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("blocks.jsonl", "one\n")
        let before = try fingerprint(config)
        #expect(try fingerprint(config) == before)

        try write("blocks.jsonl", "two\n")
        let edited = try fingerprint(config)
        #expect(edited != before)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: config.appendingPathComponent("blocks.jsonl").path
        )
        let chmodded = try fingerprint(config)
        #expect(chmodded != edited)

        try write("mcp.json", "{}\n")
        #expect(try fingerprint(config) != chmodded)
    }

    @Test func ignoreSkipsOnlyTheNamedTopLevelEntry() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("audit.jsonl", "x\n")
        let before = try fingerprint(config, ignoring: ["workspaces"])

        try write("workspaces/ws-1/home/.gitconfig", "[user]\n")
        #expect(try fingerprint(config, ignoring: ["workspaces"]) == before)

        try write("nested/workspaces/file", "x\n")
        #expect(try fingerprint(config, ignoring: ["workspaces"]) != before)
    }
}
