import Foundation

/// Shared read/update for `~/.config/rv/config.json` object keys.
enum MachineConfigJSON {
    static func load(from file: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return root
    }

    static func update(file: URL, mutate: (inout [String: Any]) -> Void) throws {
        var root = load(from: file)
        mutate(&root)
        try write(root, to: file)
    }

    static func write(_ root: [String: Any], to file: URL) throws {
        guard JSONSerialization.isValidJSONObject(root) else {
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
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
    }
}
