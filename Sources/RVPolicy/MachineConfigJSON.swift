import Foundation
import RVDomain

/// Shared read/update for `~/.config/rv/config.json` object keys.
enum MachineConfigJSON {
    static func load(from file: URL) -> [String: JSONValue] {
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let root = value.asObject
        else {
            return [:]
        }
        return root
    }

    static func update(file: URL, mutate: (inout [String: JSONValue]) -> Void) throws {
        var root = load(from: file)
        mutate(&root)
        try write(root, to: file)
    }

    static func write(_ root: [String: JSONValue], to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(JSONValue.object(root)) else {
            throw SafetyStoreError.invalidFile
        }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
    }
}
