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
    static let preToolUseKey = "preToolUse"
    static let fingerprint = "rv-guard.py"
    static let timeout = CursorRVSlice.defaultTimeout
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
        CursorRVSlice(
            adapterPath: adapterPath,
            timeout: timeout,
            failClosed: CursorRVSlice.defaultFailClosed,
            registersPreToolUse: true
        ).hookObject()
    }

    /// Returns merged hooks bytes and whether content changed.
    static func merge(
        existingData: Data?,
        adapterPath: String
    ) throws -> (data: Data, wrote: Bool) {
        let remainder = try parseRoot(existingData)
        let slice = CursorRVSlice(
            adapterPath: adapterPath,
            timeout: timeout,
            failClosed: CursorRVSlice.defaultFailClosed,
            registersPreToolUse: true
        )
        var next = slice.inserting(into: stripFingerprinted(from: remainder))
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

    static func hasFileToolEntry(in root: [String: Any]) -> Bool {
        CursorRVSlice.decode(from: root)?.registersPreToolUse == true
    }

    private static func stripFingerprinted(from root: [String: Any]) -> [String: Any] {
        guard var hooksRoot = root[hooksRootKey] as? [String: Any] else {
            return root
        }
        hooksRoot = stripFingerprinted(fromHooksRoot: hooksRoot, key: beforeShellKey)
        hooksRoot = stripFingerprinted(fromHooksRoot: hooksRoot, key: preToolUseKey)

        var next = root
        if hooksRoot.isEmpty {
            next.removeValue(forKey: hooksRootKey)
        } else {
            next[hooksRootKey] = hooksRoot
        }
        return next
    }

    private static func stripFingerprinted(
        fromHooksRoot hooksRoot: [String: Any],
        key: String
    ) -> [String: Any] {
        guard let entries = hooksRoot[key] as? [[String: Any]] else {
            return hooksRoot
        }
        let nextEntries = entries.filter { isFingerprintedHook($0) == false }
        var next = hooksRoot
        if nextEntries.isEmpty {
            next.removeValue(forKey: key)
        } else {
            next[key] = nextEntries
        }
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

/// Typed RV hooks.json slice. Foreign handlers stay in the remainder bag.
struct CursorRVSlice: Equatable, Sendable {
    static let defaultTimeout = 5
    static let defaultFailClosed = true

    var adapterPath: String
    var timeout: Int
    var failClosed: Bool
    var registersPreToolUse: Bool

    func hookObject() -> [String: Any] {
        [
            "command": CursorHooksMerge.hookCommand(adapterPath: adapterPath),
            "failClosed": failClosed,
            "timeout": timeout,
        ]
    }

    func inserting(into remainder: [String: Any]) -> [String: Any] {
        var next = remainder
        var hooksRoot = next[CursorHooksMerge.hooksRootKey] as? [String: Any] ?? [:]
        var beforeShell = hooksRoot[CursorHooksMerge.beforeShellKey] as? [[String: Any]] ?? []
        beforeShell.append(hookObject())
        hooksRoot[CursorHooksMerge.beforeShellKey] = beforeShell
        if registersPreToolUse {
            var preToolUse = hooksRoot[CursorHooksMerge.preToolUseKey] as? [[String: Any]] ?? []
            preToolUse.append(hookObject())
            hooksRoot[CursorHooksMerge.preToolUseKey] = preToolUse
        }
        next[CursorHooksMerge.hooksRootKey] = hooksRoot
        return next
    }

    static func decode(from data: Data) -> CursorRVSlice? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return decode(from: root)
    }

    static func decode(from root: [String: Any]) -> CursorRVSlice? {
        guard let hooksRoot = root[CursorHooksMerge.hooksRootKey] as? [String: Any] else {
            return nil
        }
        let before = (hooksRoot[CursorHooksMerge.beforeShellKey] as? [[String: Any]]) ?? []
        let preToolUse = (hooksRoot[CursorHooksMerge.preToolUseKey] as? [[String: Any]]) ?? []
        let rvBefore = before.first(where: CursorHooksMerge.isFingerprintedHook)
        let rvPre = preToolUse.first(where: CursorHooksMerge.isFingerprintedHook)
        guard let hook = rvBefore ?? rvPre else { return nil }
        let command = (hook["command"] as? String) ?? ""
        return CursorRVSlice(
            adapterPath: CursorHooksMerge.adapterPath(in: command) ?? "",
            timeout: (hook["timeout"] as? Int) ?? CursorHooksMerge.timeout,
            failClosed: (hook["failClosed"] as? Bool) ?? false,
            registersPreToolUse: rvPre != nil
        )
    }
}
