import Foundation

/// Merge / inspect / uninstall for `$HOME/.claude/settings.json` (REQ-012..015).
/// Command is `python3` on the exclusive adapter; baked rv stays in `RV_BINARY=`
/// so doctor/inspect still check sibling `rv-cli` without changing HostAdapterInstallation.
/// Occupied is a foreign/tampered `rv-guard.py` that is not current. Stale
/// `hook --host claude` is outdated rv: setup rewrites without `--force`.
enum ClaudeSettingsMerge {
    static let settingsFileName = "settings.json"
    static let hooksRootKey = "hooks"
    static let preToolUseKey = "PreToolUse"
    static let fingerprintLegacy = "hook --host claude"
    static let fingerprint = "rv-guard.py"
    static let matcher = "Bash"
    static let fileMatchers = ["Read", "Edit", "Write"]
    static var matchers: [String] { [matcher] + fileMatchers }
    static let hookType = "command"
    /// Claude waits this long for the wrapper, including the human confirm dialog.
    static let timeout = 90

    static func adapterPath(settingsPath: String) -> String {
        (settingsPath as NSString).deletingLastPathComponent + "/hooks/rv-guard.py"
    }

    static func hookCommand(rvPath: String, adapterPath: String) -> String {
        "RV_BINARY=\(rvPath) python3 \(adapterPath)"
    }

    static func isFingerprinted(command: String) -> Bool {
        command.contains(fingerprintLegacy) || command.contains(fingerprint)
    }

    static func adapterPath(in command: String) -> String? {
        let marker = " python3 "
        if let range = command.range(of: marker) {
            let path = String(command[range.upperBound...])
            return path.hasPrefix("/") ? path : nil
        }
        let prefix = "python3 "
        guard command.hasPrefix(prefix) else { return nil }
        let path = String(command.dropFirst(prefix.count))
        return path.hasPrefix("/") ? path : nil
    }

    static func bakedRvPath(in command: String) -> String? {
        let envPrefix = "RV_BINARY="
        if command.hasPrefix(envPrefix) {
            let rest = command.dropFirst(envPrefix.count)
            guard let space = rest.firstIndex(of: " ") else { return nil }
            let path = String(rest[..<space])
            return path.hasPrefix("/") && path.isEmpty == false ? path : nil
        }
        let suffix = " \(fingerprintLegacy)"
        guard command.hasSuffix(suffix) else { return nil }
        let path = String(command.dropLast(suffix.count))
        guard path.hasPrefix("python3 ") == false, path.contains(" python3 ") == false else {
            return nil
        }
        return path.hasPrefix("/") && path.isEmpty == false ? path : nil
    }

    static func matchesCurrentHook(_ hook: [String: Any]) -> Bool {
        guard let type = hook["type"] as? String, type == hookType,
              let command = hook["command"] as? String,
              let path = bakedRvPath(in: command),
              path.hasPrefix("/"),
              let adapter = adapterPath(in: command),
              adapter.hasPrefix("/"),
              adapter.hasSuffix("/hooks/rv-guard.py"),
              hook["timeout"] as? Int == timeout
        else {
            return false
        }
        return command == hookCommand(rvPath: path, adapterPath: adapter)
    }

    static func isFingerprintedHook(_ hook: [String: Any]) -> Bool {
        guard let type = hook["type"] as? String, type == hookType,
              let command = hook["command"] as? String
        else {
            return false
        }
        return isFingerprinted(command: command)
    }

    /// v1 `…/rv hook --host claude` is our stale command, not a foreign guard.
    static func isStaleLegacyHook(_ hook: [String: Any]) -> Bool {
        guard let type = hook["type"] as? String, type == hookType,
              let command = hook["command"] as? String
        else {
            return false
        }
        return command.contains(fingerprintLegacy) && command.contains(fingerprint) == false
    }

    static func rvEntry(rvPath: String, adapterPath: String, matcher: String) -> [String: Any] {
        [
            "matcher": matcher,
            "hooks": [
                [
                    "type": hookType,
                    "command": hookCommand(rvPath: rvPath, adapterPath: adapterPath),
                    "timeout": timeout,
                ] as [String: Any],
            ],
        ]
    }

    static func hasFileToolMatchers(in root: [String: Any]) -> Bool {
        let present = Set(locateFingerprintedHooks(in: root).compactMap { $0.entry["matcher"] as? String })
        return Set(fileMatchers).isSubset(of: present)
    }

    /// Returns merged settings bytes and whether content changed.
    static func merge(
        existingData: Data?,
        rvPath: String,
        adapterPath: String,
        force: Bool
    ) throws -> (data: Data, wrote: Bool) {
        let root = try parseRoot(existingData)
        if force == false, inspectionState(of: root) == .occupied {
            preconditionFailure("merge called on occupied settings without --force")
        }
        var next = stripFingerprinted(from: root)
        next = insertRVEntry(into: next, rvPath: rvPath, adapterPath: adapterPath)
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
        /// Our v1 `hook --host claude` command. Setup rewrites without `--force`.
        case outdated
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

        var allCurrent = true
        var hasStaleLegacy = false
        var hasNonCurrentGuard = false
        for item in located {
            if let itemMatcher = item.entry["matcher"] as? String,
               matchers.contains(itemMatcher),
               matchesCurrentHook(item.hook)
            {
                continue
            }
            allCurrent = false
            if isStaleLegacyHook(item.hook) {
                hasStaleLegacy = true
            } else {
                hasNonCurrentGuard = true
            }
        }

        if allCurrent {
            guard let bakedPath = located.compactMap({
                bakedRvPath(in: ($0.hook["command"] as? String) ?? "")
            }).first
            else {
                return .occupied
            }
            let present = Set(located.compactMap { $0.entry["matcher"] as? String })
            if Set(matchers).isSubset(of: present) {
                return .wired(bakedPath: bakedPath)
            }
            return .outdated
        }
        if hasNonCurrentGuard {
            return .occupied
        }
        if hasStaleLegacy {
            return .outdated
        }
        return .occupied
    }

    private struct LocatedHook {
        var entry: [String: Any]
        var hook: [String: Any]
    }

    private static func locateFingerprintedHooks(in root: [String: Any]) -> [LocatedHook] {
        guard let hooksRoot = root[hooksRootKey] as? [String: Any],
              let preToolUse = hooksRoot[preToolUseKey] as? [[String: Any]]
        else {
            return []
        }
        var located: [LocatedHook] = []
        for entry in preToolUse {
            guard let hooks = entry["hooks"] as? [[String: Any]] else { continue }
            for hook in hooks where isFingerprintedHook(hook) {
                located.append(LocatedHook(entry: entry, hook: hook))
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

    private static func insertRVEntry(
        into root: [String: Any],
        rvPath: String,
        adapterPath: String
    ) -> [String: Any] {
        var next = root
        var hooksRoot = next[hooksRootKey] as? [String: Any] ?? [:]
        var preToolUse = hooksRoot[preToolUseKey] as? [[String: Any]] ?? []
        for name in matchers {
            preToolUse.append(rvEntry(rvPath: rvPath, adapterPath: adapterPath, matcher: name))
        }
        hooksRoot[preToolUseKey] = preToolUse
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
