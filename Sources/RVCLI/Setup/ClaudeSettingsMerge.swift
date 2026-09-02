import Foundation

/// Merge / inspect / uninstall for `$HOME/.claude/settings.json` (REQ-012..015).
enum ClaudeSettingsMerge {
    static let settingsFileName = "settings.json"
    static let hooksRootKey = "hooks"
    static let preToolUseKey = "PreToolUse"
    static let permissionRequestKey = "PermissionRequest"
    static let fingerprint = "hook --host claude"
    static let matcher = "Bash"
    static let hookType = "command"
    static let timeout = 5

    static func hookCommand(rvPath: String) -> String {
        "\(rvPath) \(fingerprint)"
    }

    static func isFingerprinted(command: String) -> Bool {
        command.contains(fingerprint)
    }

    static func bakedRvPath(in command: String) -> String? {
        guard isFingerprinted(command: command) else { return nil }
        let suffix = " \(fingerprint)"
        guard command.hasSuffix(suffix) else { return nil }
        let path = String(command.dropLast(suffix.count))
        return path.isEmpty ? nil : path
    }

    static func matchesCurrentHook(_ hook: [String: Any]) -> Bool {
        guard let type = hook["type"] as? String, type == hookType,
              let command = hook["command"] as? String,
              let path = bakedRvPath(in: command),
              path.hasPrefix("/"),
              hook["timeout"] as? Int == timeout
        else {
            return false
        }
        return command == hookCommand(rvPath: path)
    }

    static func isFingerprintedHook(_ hook: [String: Any]) -> Bool {
        guard let type = hook["type"] as? String, type == hookType,
              let command = hook["command"] as? String
        else {
            return false
        }
        return isFingerprinted(command: command)
    }

    static func rvEntry(rvPath: String) -> [String: Any] {
        [
            "matcher": matcher,
            "hooks": [
                [
                    "type": hookType,
                    "command": hookCommand(rvPath: rvPath),
                    "timeout": timeout,
                ] as [String: Any],
            ],
        ]
    }

    /// Returns merged settings bytes and whether content changed.
    static func merge(
        existingData: Data?,
        rvPath: String,
        force: Bool
    ) throws -> (data: Data, wrote: Bool) {
        let root = try parseRoot(existingData)
        if force == false, inspectionState(of: root) == .occupied {
            preconditionFailure("merge called on occupied settings without --force")
        }
        var next = stripFingerprinted(from: root)
        next = insertRVEntry(into: next, rvPath: rvPath)
        let data = try encode(next)
        let wrote = existingData != data
        return (data, wrote)
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

    enum InspectionState: Equatable {
        case absentFile
        case occupied
        case wired(bakedPath: String)
    }

    static func inspectionState(of data: Data?) -> InspectionState {
        guard let data else { return .absentFile }
        guard let root = try? parseRoot(data) else { return .occupied }
        return inspectionState(of: root)
    }

    static func inspectionState(of root: [String: Any]) -> InspectionState {
        let located = locateFingerprintedHooks(in: root)
        guard located.isEmpty == false else { return .absentFile }

        for item in located {
            guard item.entry["matcher"] as? String == matcher,
                  matchesCurrentHook(item.hook)
            else {
                return .occupied
            }
        }

        guard let bakedPath = located.compactMap({ bakedRvPath(in: ($0.hook["command"] as? String) ?? "") }).first
        else {
            return .occupied
        }
        return .wired(bakedPath: bakedPath)
    }

    private struct LocatedHook {
        var entry: [String: Any]
        var hook: [String: Any]
    }

    private static func locateFingerprintedHooks(in root: [String: Any]) -> [LocatedHook] {
        guard let hooksRoot = root[hooksRootKey] as? [String: Any] else {
            return []
        }
        var located: [LocatedHook] = []
        for key in [preToolUseKey, permissionRequestKey] {
            guard let entries = hooksRoot[key] as? [[String: Any]] else { continue }
            for entry in entries {
                guard let hooks = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in hooks where isFingerprintedHook(hook) {
                    located.append(LocatedHook(entry: entry, hook: hook))
                }
            }
        }
        return located
    }

    private static func parseRoot(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeSettingsMergeError.unreadable
        }
        return object
    }

    private static func stripFingerprinted(from root: [String: Any]) -> [String: Any] {
        guard var hooksRoot = root[hooksRootKey] as? [String: Any] else {
            return root
        }
        for key in [preToolUseKey, permissionRequestKey] {
            guard let entries = hooksRoot[key] as? [[String: Any]] else { continue }
            var nextEntries: [[String: Any]] = []
            for var entry in entries {
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
                hooksRoot.removeValue(forKey: key)
            } else {
                hooksRoot[key] = nextEntries
            }
        }

        var next = root
        if hooksRoot.isEmpty {
            next.removeValue(forKey: hooksRootKey)
        } else {
            next[hooksRootKey] = hooksRoot
        }
        return next
    }

    private static func insertRVEntry(into root: [String: Any], rvPath: String) -> [String: Any] {
        var next = root
        var hooksRoot = next[hooksRootKey] as? [String: Any] ?? [:]
        for key in [preToolUseKey, permissionRequestKey] {
            var entries = hooksRoot[key] as? [[String: Any]] ?? []
            entries.append(rvEntry(rvPath: rvPath))
            hooksRoot[key] = entries
        }
        next[hooksRootKey] = hooksRoot
        return next
    }

    private static func encode(_ root: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw ClaudeSettingsMergeError.unreadable
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
    }
}

enum ClaudeSettingsMergeError: Error, Equatable {
    case unreadable
}
