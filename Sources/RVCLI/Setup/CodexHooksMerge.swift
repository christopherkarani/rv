import Foundation

/// Merge / inspect / uninstall for `$HOME/.codex/hooks.json`.
/// Occupancy of the setup slot is the exclusive `rv-guard.py`; this merge only
/// registers that adapter under PreToolUse / Bash and strips the fingerprint.
enum CodexHooksMerge {
    static let hooksFileName = "hooks.json"
    static let hooksRootKey = "hooks"
    static let preToolUseKey = "PreToolUse"
    static let fingerprint = "rv-guard.py"
    static let matcher = CodexRVSlice.shellMatcher
    static let hookType = "command"
    static let timeout = CodexRVSlice.defaultTimeout
    static let statusMessage = CodexRVSlice.defaultStatusMessage

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
        guard let type = hook["type"] as? String, type == hookType,
              let command = hook["command"] as? String,
              command == hookCommand(adapterPath: adapterPath),
              hook["timeout"] as? Int == timeout
        else {
            return false
        }
        return true
    }

    static func isFingerprintedHook(_ hook: [String: Any]) -> Bool {
        guard let type = hook["type"] as? String, type == hookType,
              let command = hook["command"] as? String
        else {
            return false
        }
        return isFingerprinted(command: command)
    }

    static func rvEntry(adapterPath: String) -> [String: Any] {
        CodexRVSlice(
            adapterPath: adapterPath,
            matcher: matcher,
            timeout: timeout,
            statusMessage: statusMessage
        ).entry()
    }

    /// Returns merged hooks bytes and whether content changed.
    static func merge(
        existingData: Data?,
        adapterPath: String
    ) throws -> (data: Data, wrote: Bool) {
        let remainder = try parseRoot(existingData)
        let slice = CodexRVSlice(
            adapterPath: adapterPath,
            matcher: CodexRVSlice.shellMatcher,
            timeout: CodexRVSlice.defaultTimeout,
            statusMessage: CodexRVSlice.defaultStatusMessage
        )
        let next = slice.inserting(into: stripFingerprinted(from: remainder))
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
        return try encode(stripped)
    }

    private static func parseRoot(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexHooksMergeError.unreadable
        }
        return object
    }

    private static func stripFingerprinted(from root: [String: Any]) -> [String: Any] {
        guard var hooksRoot = root[hooksRootKey] as? [String: Any],
              let preToolUse = hooksRoot[preToolUseKey] as? [[String: Any]]
        else {
            return root
        }

        var nextEntries: [[String: Any]] = []
        for var entry in preToolUse {
            guard var hooks = entry["hooks"] as? [[String: Any]] else {
                nextEntries.append(entry)
                continue
            }
            hooks.removeAll(where: isFingerprintedHook)
            guard hooks.isEmpty == false else { continue }
            entry["hooks"] = hooks
            nextEntries.append(entry)
        }

        if nextEntries.isEmpty {
            hooksRoot.removeValue(forKey: preToolUseKey)
        } else {
            hooksRoot[preToolUseKey] = nextEntries
        }

        var next = root
        if hooksRoot.isEmpty {
            next.removeValue(forKey: hooksRootKey)
        } else {
            next[hooksRootKey] = hooksRoot
        }
        return next
    }

    private static func encode(_ root: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw CodexHooksMergeError.unreadable
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
    }
}

enum CodexHooksMergeError: Error, Equatable {
    case unreadable
}

/// Typed RV PreToolUse slice. Shell matcher only — no file-tool registration.
struct CodexRVSlice: Equatable, Sendable {
    static let shellMatcher = "Bash"
    static let defaultTimeout = 5
    static let defaultStatusMessage = "RV"

    var adapterPath: String
    var matcher: String
    var timeout: Int
    var statusMessage: String

    func entry() -> [String: Any] {
        [
            "matcher": matcher,
            "hooks": [
                [
                    "type": CodexHooksMerge.hookType,
                    "command": CodexHooksMerge.hookCommand(adapterPath: adapterPath),
                    "timeout": timeout,
                    "statusMessage": statusMessage,
                ] as [String: Any],
            ],
        ]
    }

    func inserting(into remainder: [String: Any]) -> [String: Any] {
        var next = remainder
        var hooksRoot = next[CodexHooksMerge.hooksRootKey] as? [String: Any] ?? [:]
        var preToolUse = hooksRoot[CodexHooksMerge.preToolUseKey] as? [[String: Any]] ?? []
        preToolUse.append(entry())
        hooksRoot[CodexHooksMerge.preToolUseKey] = preToolUse
        next[CodexHooksMerge.hooksRootKey] = hooksRoot
        return next
    }

    static func decode(from data: Data) -> CodexRVSlice? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return decode(from: root)
    }

    static func decode(from root: [String: Any]) -> CodexRVSlice? {
        guard let hooksRoot = root[CodexHooksMerge.hooksRootKey] as? [String: Any],
              let preToolUse = hooksRoot[CodexHooksMerge.preToolUseKey] as? [[String: Any]]
        else {
            return nil
        }
        for entry in preToolUse {
            guard let hooks = entry["hooks"] as? [[String: Any]],
                  let hook = hooks.first(where: CodexHooksMerge.isFingerprintedHook)
            else {
                continue
            }
            let command = (hook["command"] as? String) ?? ""
            return CodexRVSlice(
                adapterPath: CodexHooksMerge.adapterPath(in: command) ?? "",
                matcher: (entry["matcher"] as? String) ?? CodexHooksMerge.matcher,
                timeout: (hook["timeout"] as? Int) ?? CodexHooksMerge.timeout,
                statusMessage: (hook["statusMessage"] as? String) ?? CodexHooksMerge.statusMessage
            )
        }
        return nil
    }
}
