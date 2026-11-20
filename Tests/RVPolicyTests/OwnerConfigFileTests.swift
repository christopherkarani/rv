import Foundation
import RVDomain
import RVHistory
import Testing
@testable import RVPolicy

/// The owner-config write every config writer goes through: strict prior,
/// write-ahead change event, owner-only atomic replace in an owner-only
/// directory. Each store has one thin test of its own
/// (`OwnerConfigWritersTests`); the rules are tested here, once.
struct OwnerConfigFileTests {
    /// Text `GuardConfig(jsonData:)` rejects (it reads as `.empty`,
    /// enforce) while `JSONDecoder` still decodes it. A writer that decoded
    /// and re-encoded it would pick one reading and could store observe.
    static let ambiguousTexts: [Data] = [
        Data(#"{"guard":{"mode":"observe"},"guard":{"mode":"enforce"}}"#.utf8),
        Data(#"{"guard":{"mode":"observe","mode":"enforce"}}"#.utf8),
        Data("{\"\u{FEFF}guard\":{\"mode\":\"observe\"}}".utf8),
        Data(("{\"guard\":{\"mode\":\"observe\"},\"deep\":" + String(repeating: "[", count: 70)
            + String(repeating: "]", count: 70) + "}").utf8),
        #"{"guard":{"mode":"observe"}}"#.data(using: .utf16BigEndian)!,
    ]

    static let hostSetting = MachineConfigJSON.Setting(
        keyPath: ["guard", "hosts", "claude"], describe: { $0?.string ?? ConfigChangeAudit.unset },
        direction: { _, _ in .loosening })

    @Test func everyFixture_decodes_butTheGuardReaderRejectsIt() throws {
        for text in Self.ambiguousTexts {
            #expect((try? JSONDecoder().decode(JSONValue.self, from: text))?.asObject != nil)
            #expect(GuardConfig(jsonData: text) == .empty)
        }
    }

    @Test(arguments: ambiguousTexts)
    func set_refusesAmbiguousTextAndLeavesTheFile(text: Data) throws {
        try withConfig(text) { file throws in
            var ranBeforeWrite = false
            #expect(throws: OwnerConfigWriteError.unreadable) {
                try MachineConfigJSON.set(.string("observe"), for: Self.hostSetting, in: file) { ranBeforeWrite = true }
            }
            #expect(ranBeforeWrite == false)
            #expect(try Data(contentsOf: file) == text)
            #expect(changes(file.deletingLastPathComponent()).isEmpty)
        }
    }

    /// A prior of the wrong shape, at the root or on the way to the key, is
    /// refused: replacing it with `{}` would drop what the owner keeps there.
    @Test(arguments: [
        "{not json",
        #"[1, 2]"#,
        #""observe""#,
        #"{"guard":"observe","safety":{"level":"strict"}}"#,
        #"{"guard":null}"#,
        #"{"guard":{"mode":"observe","hosts":["claude"]}}"#,
        #"{"guard":{"hosts":"off"}}"#,
    ])
    func set_refusesAWrongShapedPrior(json: String) throws {
        try withConfig(Data(json.utf8)) { file throws in
            #expect(throws: OwnerConfigWriteError.unreadable) {
                try MachineConfigJSON.set(.string("block"), for: Self.hostSetting, in: file)
            }
            #expect(try String(contentsOf: file, encoding: .utf8) == json)
        }
    }

    /// A prior that exists but cannot be read is refused, not read as empty.
    @Test func update_refusesAnUnreadablePrior() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var mutated = false
        #expect(throws: OwnerConfigWriteError.unreadable) {
            try textFile(file).update(audit: { _, _ in nil }) { _ in mutated = true }
        }
        #expect(mutated == false)
    }

    @Test func update_refusesWhatParseRejects() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.toml")
        let bytes = Data([0xFF, 0xFE, 0x5B, 0x70])
        try bytes.write(to: file)
        var mutated = false
        #expect(throws: OwnerConfigWriteError.unreadable) {
            try textFile(file).update(audit: { _, _ in nil }) { _ in mutated = true }
        }
        #expect(mutated == false)
        #expect(try Data(contentsOf: file) == bytes)
    }

    /// A leading byte-order mark on the document (not in a key) is text the
    /// guard reader accepts, so it is still writable.
    @Test func leadingDocumentBOM_isStillWritable() throws {
        let text = Data("\u{FEFF}{\"guard\":{\"mode\":\"enforce\"}}".utf8)
        #expect(GuardConfig(jsonData: text).mode == .enforce)
        try withConfig(text) { file throws in
            try MachineConfigJSON.set(.string("block"), for: Self.hostSetting, in: file)
            let written = GuardConfig(jsonData: try Data(contentsOf: file))
            #expect(written.mode == .enforce)
            #expect(written.hosts == [.claude: .block])
        }
    }

    @Test func set_keepsSiblingKeysAndWritesOwnerOnlyInAnOwnerOnlyDirectory() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("cfg", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let file = nested.appendingPathComponent("config.json")
        try Data(#"{"analytics":{"enabled":false},"guard":{"mode":"enforce"}}"#.utf8).write(to: file)
        try MachineConfigJSON.set(.string("observe"), for: Self.hostSetting, in: file)
        let loaded = MachineConfigJSON.load(from: file)
        #expect(loaded["analytics"]?["enabled"]?.bool == false)
        #expect(loaded["guard"]?["mode"]?.string == "enforce")
        #expect(loaded["guard"]?["hosts"]?["claude"]?.string == "observe")
        #expect(try posixMode(nested) == 0o700)
        #expect(try posixMode(file) == 0o600)
    }

    @Test func load_missingAndNonObject_areEmpty() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        #expect(MachineConfigJSON.load(from: file).isEmpty)
        try Data("not-json".utf8).write(to: file)
        #expect(MachineConfigJSON.load(from: file).isEmpty)
        try Data("[1,2,3]".utf8).write(to: file)
        #expect(MachineConfigJSON.load(from: file).isEmpty)
    }

    @Test func update_renderFailure_writesAndRecordsNothing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        #expect(throws: OwnerConfigWriteError.unwritable) {
            try MachineConfigJSON.file(file).update(audit: { _, _ in event("when") }) { object in
                object["when"] = .number(.infinity)
            }
        }
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
        #expect(changes(root).isEmpty)
    }

    @Test func update_aThrowingMutateWritesAndRecordsNothing() throws {
        try withConfig(Data(#"{"a":1}"#.utf8)) { file throws in
            struct Refused: Error {}
            #expect(throws: Refused.self) {
                try MachineConfigJSON.file(file).update(audit: { _, _ in event("a") }) { object in
                    object["a"] = .number(2)
                    throw Refused()
                }
            }
            #expect(try String(contentsOf: file, encoding: .utf8) == #"{"a":1}"#)
            #expect(changes(file.deletingLastPathComponent()).isEmpty)
        }
    }

    /// The event lands before `beforeWrite` runs and before the file moves;
    /// a value whose reading did not change records nothing.
    @Test func set_recordsTheChangeWriteAheadOnce() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        var seenBeforeWrite: (events: Int, fileExists: Bool)?
        try MachineConfigJSON.set(.string("observe"), for: Self.hostSetting, in: file) {
            seenBeforeWrite = (changes(root).count, FileManager.default.fileExists(atPath: file.path))
        }
        #expect(seenBeforeWrite?.events == 1)
        #expect(seenBeforeWrite?.fileExists == false)
        try MachineConfigJSON.set(.string("observe"), for: Self.hostSetting, in: file)
        let events = changes(root)
        #expect(events.count == 1)
        #expect(events.first?.subject == "guard.hosts.claude")
        #expect(events.first?.detail["prior"] == "unset")
        #expect(events.first?.detail["new"] == "observe")
        #expect(events.first?.detail["direction"] == "loosening")
        let report = try AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: root)).get()
        #expect(report.isIntact)
    }

    @Test func update_anUnrecordableLooseningChangeIsNotWritten() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.toml")
        try Data("before".utf8).write(to: file)
        try breakLog(root)
        var ranBeforeWrite = false
        #expect(throws: ConfigChangeUnrecorded.self) {
            try textFile(file).update(audit: { _, _ in event("text") }, beforeWrite: { ranBeforeWrite = true }) {
                $0 = "after"
            }
        }
        #expect(ranBeforeWrite == false)
        #expect(try String(contentsOf: file, encoding: .utf8) == "before")
    }

    @Test func update_anUnrecordableTighteningChangeIsStillWritten() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.toml")
        try breakLog(root)
        try textFile(file).update(audit: { _, _ in event("text", direction: .tightening) }) { $0 = "after" }
        #expect(try String(contentsOf: file, encoding: .utf8) == "after")
        #expect(try posixMode(file) == 0o600)
    }

    private func textFile(_ url: URL) -> OwnerConfigFile<String> {
        OwnerConfigFile(
            url: url, empty: "", parse: { String(data: $0, encoding: .utf8) }, render: { Data($0.utf8) })
    }

    private func event(_ name: String, direction: ConfigChangeAudit.Direction = .loosening) -> AuditEvent {
        ConfigChangeAudit.setting(name, from: "a", to: "b", direction: direction)
    }

    private func changes(_ configDirectory: URL) -> [AuditEvent] {
        AuditLedger(configDirectory: configDirectory).events(AuditFilter(kinds: ["config"]))
    }

    /// audit.jsonl as a directory: every append fails.
    private func breakLog(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: AuditLog.fileURL(configDirectory: directory), withIntermediateDirectories: true)
    }

    private func withConfig(_ text: Data, _ body: (URL) throws -> Void) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try text.write(to: file)
        try body(file)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-owner-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func posixMode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
    }
}
