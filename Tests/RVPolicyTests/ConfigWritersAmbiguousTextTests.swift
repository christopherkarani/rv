import Foundation
import RVDomain
import Testing
@testable import RVPolicy

/// Text `GuardConfig(jsonData:)` rejects (it reads as `.empty`, enforce)
/// while `JSONDecoder` still decodes it. A writer that decoded and
/// re-encoded it would pick one reading and could store observe, so every
/// `config.json` writer refuses it and leaves the bytes as they were.
struct ConfigWritersAmbiguousTextTests {
    static let ambiguousTexts: [Data] = [
        Data(#"{"guard":{"mode":"observe"},"guard":{"mode":"enforce"}}"#.utf8),
        Data(#"{"guard":{"mode":"observe","mode":"enforce"}}"#.utf8),
        Data("{\"\u{FEFF}guard\":{\"mode\":\"observe\"}}".utf8),
        Data(("{\"guard\":{\"mode\":\"observe\"},\"deep\":" + String(repeating: "[", count: 70)
            + String(repeating: "]", count: 70) + "}").utf8),
        #"{"guard":{"mode":"observe"}}"#.data(using: .utf16BigEndian)!,
    ]

    @Test func everyFixture_decodes_butTheGuardReaderRejectsIt() throws {
        for text in Self.ambiguousTexts {
            #expect((try? JSONDecoder().decode(JSONValue.self, from: text))?.asObject != nil)
            #expect(GuardConfig(jsonData: text) == .empty)
        }
    }

    @Test(arguments: ambiguousTexts)
    func update_refusesAndLeavesTheFile(text: Data) throws {
        try withConfig(text) { file throws in
            #expect(throws: MachineConfigJSONError.unreadableConfig) {
                try MachineConfigJSON.update(file: file) { $0["analytics"] = .object(["enabled": .bool(false)]) }
            }
            #expect(try Data(contentsOf: file) == text)
        }
    }

    @Test(arguments: ambiguousTexts)
    func updateExistingObject_refusesAndLeavesTheFile(text: Data) throws {
        try withConfig(text) { file throws in
            var mutated = false
            #expect(throws: MachineConfigJSONError.unreadableConfig) {
                try MachineConfigJSON.updateExistingObject(file: file) { _ in mutated = true }
            }
            #expect(mutated == false)
            #expect(try Data(contentsOf: file) == text)
        }
    }

    @Test(arguments: ambiguousTexts)
    func hostModeSave_refusesAndLeavesTheFile(text: Data) throws {
        try withConfig(text) { file throws in
            let store = HostModeStore(configDirectory: file.deletingLastPathComponent())
            var detached = false
            #expect(throws: HostModeStoreError.unreadableConfig) {
                try store.save(.block, for: .claude) { detached = true }
            }
            #expect(detached == false)
            #expect(try Data(contentsOf: file) == text)
        }
    }

    @Test(arguments: ambiguousTexts)
    func saveGlobalObserve_refusesAndLeavesTheFile(text: Data) throws {
        try withConfig(text) { file throws in
            let store = HostModeStore(configDirectory: file.deletingLastPathComponent())
            #expect(throws: HostModeStoreError.unreadableConfig) { try store.saveGlobalObserve() }
            #expect(try Data(contentsOf: file) == text)
        }
    }

    @Test(arguments: ambiguousTexts)
    func safetySaveMachine_refusesAndLeavesTheFile(text: Data) throws {
        try withConfig(text) { file throws in
            let store = SafetyStore(configDirectory: file.deletingLastPathComponent())
            #expect(throws: MachineConfigJSONError.unreadableConfig) { try store.saveMachine(.strict) }
            #expect(try Data(contentsOf: file) == text)
        }
    }

    @Test(arguments: ambiguousTexts)
    func secretAllowPathWriters_refuseAndLeaveTheFile(text: Data) throws {
        try withConfig(text) { file throws in
            #expect(throws: MachineConfigJSONError.unreadableConfig) {
                try SecretAllowPaths.saveMachineConfig([".env"], to: file)
            }
            #expect(throws: MachineConfigJSONError.unreadableConfig) {
                try SecretAllowPaths.saveBlessPaths(["repo"], to: file)
            }
            #expect(try Data(contentsOf: file) == text)
        }
    }

    /// A leading byte-order mark on the document (not in a key) is text the
    /// guard reader accepts, so writers still accept it.
    @Test func leadingDocumentBOM_isStillWritable() throws {
        let text = Data("\u{FEFF}{\"guard\":{\"mode\":\"enforce\"}}".utf8)
        #expect(GuardConfig(jsonData: text).mode == .enforce)
        try withConfig(text) { file throws in
            try HostModeStore(configDirectory: file.deletingLastPathComponent()).save(.block, for: .claude)
            let written = GuardConfig(jsonData: try Data(contentsOf: file))
            #expect(written.mode == .enforce)
            #expect(written.hosts == [.claude: .block])
        }
    }

    private func withConfig(_ text: Data, _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-ambiguous-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try text.write(to: file)
        try body(file)
    }
}
