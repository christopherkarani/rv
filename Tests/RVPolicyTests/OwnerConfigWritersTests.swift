import Foundation
import RVDomain
import RVHistory
import Testing
@testable import RVPolicy

/// Thin tests per owner config writer: each goes through `OwnerConfigFile`,
/// so a prior it cannot rewrite is refused with the one refusal and left as
/// it was, and a write over a looser file (0644) in a looser directory
/// (0755) leaves both owner-only with the change on the audit trail. A
/// writer that bypassed the module would miss one of the two. The rules
/// themselves are tested once, in `OwnerConfigFileTests`.
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

    @Test func hostModeSave_tightensLooseModesAndRecordsTheChange() throws {
        try withLooseConfigDirectory(file: "config.json", holding: Data("{}".utf8)) { directory, file throws in
            try HostModeStore(configDirectory: directory).save(.block, for: .claude)
            try expectOwnerOnlyAndRecorded(directory: directory, file: file, subject: "guard.hosts.claude")
        }
    }

    @Test func hostModeSaveGlobalObserve_tightensLooseModesAndRecordsTheChange() throws {
        try withLooseConfigDirectory(file: "config.json", holding: Data("{}".utf8)) { directory, file throws in
            try HostModeStore(configDirectory: directory).saveGlobalObserve()
            try expectOwnerOnlyAndRecorded(directory: directory, file: file, subject: "guard.mode")
        }
    }

    @Test func safetySaveMachine_tightensLooseModesAndRecordsTheChange() throws {
        try withLooseConfigDirectory(file: "config.json", holding: Data("{}".utf8)) { directory, file throws in
            try SafetyStore(configDirectory: directory).saveMachine(.strict)
            try expectOwnerOnlyAndRecorded(directory: directory, file: file, subject: "safety.level")
        }
    }

    @Test func packsSave_tightensLooseModesAndRecordsTheChange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-owner-writers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try #require(HomeDirectory(validating: root.path))
        let file = PacksConfigStore.configURL(home: home)
        let directory = file.deletingLastPathComponent()
        try makeLoose(directory: directory, file: file, holding: Data("[other]\nkey = 1\n".utf8))
        try PacksConfigStore.save(PacksConfig(disabled: ["core.git"]), home: home)
        try expectOwnerOnlyAndRecorded(directory: directory, file: file, subject: "packs")
    }

    @Test func allowlistAdd_tightensLooseModesAndRecordsTheChange() throws {
        try withLooseConfigDirectory(file: "allowlist.toml", holding: Data()) { directory, file throws in
            let ruleID = try #require(RuleID(rawValue: "core.git:clean-force"))
            try AllowlistStore(baseDirectory: directory).add(
                AllowlistEntry(selector: .rule(ruleID), reason: "ok", addedAt: Date()), tty: tty)
            try expectOwnerOnlyAndRecorded(directory: directory, file: file, subject: "allowlist")
        }
    }

    /// The file is 0600 in a 0700 directory, and the audit trail holds one
    /// `config.changed` row for `subject`, recorded as made.
    private func expectOwnerOnlyAndRecorded(directory: URL, file: URL, subject: String) throws {
        #expect(try posixMode(file) == 0o600)
        #expect(try posixMode(directory) == 0o700)
        let events = AuditLedger(configDirectory: directory).events(AuditFilter(kinds: ["config"]))
        #expect(events.map(\.subject) == [subject])
        #expect(events.map(\.decision) == [.info])
    }

    private func withLooseConfigDirectory(
        file name: String, holding bytes: Data, _ body: (URL, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-owner-writers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("rv", isDirectory: true)
        let file = directory.appendingPathComponent(name)
        try makeLoose(directory: directory, file: file, holding: bytes)
        try body(directory, file)
    }

    /// `file` holding `bytes` at 0644 in `directory` at 0755.
    private func makeLoose(directory: URL, file: URL, holding bytes: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try posixMode(directory) == 0o755)
        #expect(try posixMode(file) == 0o644)
    }

    private func posixMode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
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
