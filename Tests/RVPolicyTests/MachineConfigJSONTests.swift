import Foundation
import RVDomain
import Testing
@testable import RVPolicy

struct MachineConfigJSONTests {
    @Test func load_missingAndNonObject_areEmpty() throws {
        let root = try makeDirectory("missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        #expect(MachineConfigJSON.load(from: file).isEmpty)

        try Data("not-json".utf8).write(to: file)
        #expect(MachineConfigJSON.load(from: file).isEmpty)

        try Data("[1,2,3]".utf8).write(to: file)
        #expect(MachineConfigJSON.load(from: file).isEmpty)
    }

    @Test func update_preservesSiblingKeysAndSetsOwnerModes() throws {
        let root = try makeDirectory("update")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("cfg", isDirectory: true)
        let file = nested.appendingPathComponent("config.json")
        try MachineConfigJSON.update(file: file) { object in
            object["analytics"] = .object(["enabled": .bool(false)])
        }
        try MachineConfigJSON.update(file: file) { object in
            object["safety"] = .object(["level": .string("strict")])
        }
        let loaded = MachineConfigJSON.load(from: file)
        #expect(loaded["analytics"]?["enabled"]?.bool == false)
        #expect(loaded["safety"]?["level"]?.string == "strict")
        #expect(try posixMode(nested) == 0o700)
        #expect(try posixMode(file) == 0o600)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("analytics"))
        #expect(text.contains("safety"))
    }

    @Test func write_rejectsUnencodableValue() throws {
        let root = try makeDirectory("invalid")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        #expect(throws: SafetyStoreError.invalidFile) {
            try MachineConfigJSON.write(["when": .number(.infinity)], to: file)
        }
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }
}

private func makeDirectory(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-mcjson-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func posixMode(_ url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let raw = attrs[.posixPermissions] as? NSNumber
    return (raw?.intValue ?? 0) & 0o777
}
