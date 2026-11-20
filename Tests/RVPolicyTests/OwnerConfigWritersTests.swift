import Foundation
import RVDomain
import Testing
@testable import RVPolicy

/// One thin test per owner config writer: each goes through
/// `OwnerConfigFile`, so a prior it cannot rewrite is refused with the one
/// refusal and left as it was. The rules themselves are tested once, in
/// `OwnerConfigFileTests`.
struct OwnerConfigWritersTests {
    /// Repeats `guard`: `GuardConfig` reads it as enforce, `JSONDecoder`
    /// would keep the observe copy.
    static let ambiguous = Data(#"{"guard":{"mode":"observe"},"guard":{"mode":"enforce"}}"#.utf8)
    private let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)

    @Test func hostModeSave() throws {
        try withConfigDirectory(file: "config.json", holding: Self.ambiguous) { directory, file throws in
            var detached = false
            #expect(throws: OwnerConfigWriteError.unreadable) {
                try HostModeStore(configDirectory: directory).save(.block, for: .claude) { detached = true }
            }
            #expect(detached == false)
            #expect(try Data(contentsOf: file) == Self.ambiguous)
        }
    }

    @Test func hostModeSaveGlobalObserve() throws {
        try withConfigDirectory(file: "config.json", holding: Self.ambiguous) { directory, file throws in
            #expect(throws: OwnerConfigWriteError.unreadable) {
                try HostModeStore(configDirectory: directory).saveGlobalObserve()
            }
            #expect(try Data(contentsOf: file) == Self.ambiguous)
        }
    }

    @Test func safetySaveMachine() throws {
        try withConfigDirectory(file: "config.json", holding: Self.ambiguous) { directory, file throws in
            #expect(throws: OwnerConfigWriteError.unreadable) {
                try SafetyStore(configDirectory: directory).saveMachine(.strict)
            }
            #expect(try Data(contentsOf: file) == Self.ambiguous)
        }
    }

    @Test func packsSave() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-owner-writers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try #require(HomeDirectory(validating: root.path))
        let file = PacksConfigStore.configURL(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data([0xFF, 0xFE, 0x5B, 0x70])
        try bytes.write(to: file)
        #expect(throws: OwnerConfigWriteError.unreadable) {
            try PacksConfigStore.save(PacksConfig(disabled: ["core.git"]), home: home)
        }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func allowlistAdd() throws {
        // No reason: `AllowlistTOML.parse` rejects it.
        let invalid = Data("[[allow]]\nrule = \"core.git:reset-hard\"\n".utf8)
        try withConfigDirectory(file: "allowlist.toml", holding: invalid) { directory, file throws in
            let ruleID = try #require(RuleID(rawValue: "core.git:clean-force"))
            #expect(throws: OwnerConfigWriteError.unreadable) {
                try AllowlistStore(baseDirectory: directory).add(
                    AllowlistEntry(selector: .rule(ruleID), reason: "ok", addedAt: Date()), tty: tty)
            }
            #expect(try Data(contentsOf: file) == invalid)
        }
    }

    private func withConfigDirectory(
        file name: String, holding bytes: Data, _ body: (URL, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-owner-writers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(name)
        try bytes.write(to: file)
        try body(directory, file)
    }
}
