import Foundation

/// Merge / inspect / uninstall for `$HOME/.cursor/hooks.json`.
/// Occupancy of the setup slot is the exclusive `rv-guard.py`; this merge only
/// registers that adapter under official `beforeShellExecution` with
/// `failClosed: true` and strips the fingerprint.
enum CursorHooksMerge {
    static let hooksFileName = "hooks.json"
    static let versionKey = "version"
    static let hooksRootKey = "hooks"
    static let beforeShellKey = "beforeShellExecution"
    static let fingerprint = "rv-guard.py"
    static let timeout = 5
    static let schemaVersion = 1

    static func hookCommand(adapterPath: String) -> String {
        "python3 \(adapterPath)"
    }

    static func isFingerprinted(command: String) -> Bool {
        command.contains(fingerprint)
    }

    static func adapterPath(in command: String) -> String? {
        guard isFingerprinted(command: command) else { return nil }
        let prefix = "python3 "
        guard command.hasPrefix(prefix) else { return nil }
        let path = String(command.dropFirst(prefix.count))
        return path.hasPrefix("/") ? path : nil
    }

    static func matchesCurrentHook(_ hook: [String: Any], adapterPath: String) -> Bool {
        guard let command = hook["command"] as? String,
              command == hookCommand(adapterPath: adapterPath),
              hook["timeout"] as? Int == timeout,
              hook["failClosed"] as? Bool == true
        else {
            return false
        }
        return true
    }

    static func isFingerprintedHook(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else {
            return false
        }
        return isFingerprinted(command: command)
    }

    static func rvEntry(adapterPath: String) -> [String: Any] {
        [
            "command": hookCommand(adapterPath: adapterPath),
            "failClosed": true,
            "timeout": timeout,
        ]
    }

    /// Returns merged hooks bytes and whether content changed.
    static func merge(
        existingData: Data?,
        adapterPath: String
    ) throws -> (data: Data, wrote: Bool) {
        let root = try parseRoot(existingData)
        var next = stripFingerprinted(from: root)
        next = insertRVEntry(into: next, adapterPath: adapterPath)
        if next[versionKey] == nil {
            next[versionKey] = schemaVersion
        }
        let data = try encode(next)
        return (data, existingData != data)
    }

    /// Strips rv-fingerprinted hooks. Returns `nil` when the file should be removed.
    static func uninstall(existingData: Data) throws -> Data? {
        let root = try parseRoot(existingData)
        let stripped = stripFingerprinted(from: root)
        if stripped.isEmpty {
            return nil
        }
        if stripped.keys.count == 1, stripped[versionKey] != nil {
            return nil
        }
        return try encode(stripped)
    }

    private static func parseRoot(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorHooksMergeError.unreadable
        }
        return object
    }

    private static func stripFingerprinted(from root: [String: Any]) -> [String: Any] {
        guard var hooksRoot = root[hooksRootKey] as? [String: Any],
              let beforeShell = hooksRoot[beforeShellKey] as? [[String: Any]]
        else {
            return root
        }

        let nextEntries = beforeShell.filter { isFingerprintedHook($0) == false }

        if nextEntries.isEmpty {
            hooksRoot.removeValue(forKey: beforeShellKey)
        } else {
            hooksRoot[beforeShellKey] = nextEntries
        }

        var next = root
        if hooksRoot.isEmpty {
            next.removeValue(forKey: hooksRootKey)
        } else {
            next[hooksRootKey] = hooksRoot
        }
        return next
    }

    private static func insertRVEntry(into root: [String: Any], adapterPath: String) -> [String: Any] {
        var next = root
        var hooksRoot = next[hooksRootKey] as? [String: Any] ?? [:]
        var beforeShell = hooksRoot[beforeShellKey] as? [[String: Any]] ?? []
        beforeShell.append(rvEntry(adapterPath: adapterPath))
        hooksRoot[beforeShellKey] = beforeShell
        next[hooksRootKey] = hooksRoot
        return next
    }

    private static func encode(_ root: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw CursorHooksMergeError.unreadable
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
    }
}

enum CursorHooksMergeError: Error, Equatable {
    case unreadable
}
