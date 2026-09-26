import Foundation

/// Merge / inspect / uninstall for `$HOME/.claude/settings.json` (REQ-012..015).
/// Command is `python3` on the exclusive adapter; baked rv stays in `RV_BINARY=`
/// so `HostAdapterInstallation.inspect` can require sibling `rv-cli` for `.wired`.
/// Occupied is a foreign/tampered `rv-guard.py` that is not current. Stale
/// `hook --host claude` is outdated rv: setup rewrites without `--force`.
///
/// Round-trip, strip/insert/uninstall, and locate delegate to
/// `HostHooksMergeEngine` via `wiringDescriptor`; inspection (occupancy,
/// stale-legacy, matcher coverage) stays here over the engine's locate.
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

    static let wiringDescriptor = HostWiringDescriptor(
        layout: .nested(hooksRootKey: hooksRootKey, listKey: preToolUseKey),
        matchers: matchers,
        hookType: hookType,
        isFingerprintedCommand: { isFingerprinted(command: $0) },
        buildEntry: { context, _ in
            hookEntry(rvPath: context.rvPath ?? "", adapterPath: context.adapterPath)
        }
    )

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
        HostHooksMergeEngine.isFingerprintedHook(hook, descriptor: wiringDescriptor)
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

    static func hookEntry(rvPath: String, adapterPath: String) -> HookEntry {
        HookEntry(
            command: hookCommand(rvPath: rvPath, adapterPath: adapterPath),
            timeout: timeout,
            type: hookType,
            failClosed: nil,
            statusMessage: nil
        )
    }

    static func rvEntry(rvPath: String, adapterPath: String, matcher: String) -> [String: Any] {
        [
            "matcher": matcher,
            "hooks": [
                HostHooksMergeEngine.hookDictionary(
                    hookEntry(rvPath: rvPath, adapterPath: adapterPath)
                ),
            ],
        ]
    }

    static func hasFileToolMatchers(in root: [String: Any]) -> Bool {
        let present = Set(
            HostHooksMergeEngine.locateFingerprintedHooks(in: root, descriptor: wiringDescriptor)
                .compactMap { $0.matcher }
        )
        return Set(fileMatchers).isSubset(of: present)
    }

    /// Returns merged settings bytes and whether content changed.
    /// Setup writes through `HostWiring.applyClaude`.
    static func merge(
        existingData: Data?,
        rvPath: String,
        adapterPath: String,
        force: Bool
    ) throws -> (data: Data, wrote: Bool) {
        do {
            return try HostHooksMergeEngine.merge(
                existingData: existingData,
                descriptor: wiringDescriptor,
                context: HookCommandContext(rvPath: rvPath, adapterPath: adapterPath),
                willMerge: { root in
                    if force == false, inspectionState(of: root) == .occupied {
                        throw ClaudeSettingsMergeError.occupiedWithoutForce
                    }
                }
            )
        } catch let error as ClaudeSettingsMergeError {
            throw error
        } catch {
            throw ClaudeSettingsMergeError.unreadable
        }
    }

    /// Strips rv-fingerprinted hooks. Returns `nil` when the file should be removed.
    static func uninstall(existingData: Data) throws -> Data? {
        do {
            return try HostHooksMergeEngine.uninstall(
                existingData: existingData,
                descriptor: wiringDescriptor
            )
        } catch {
            throw ClaudeSettingsMergeError.unreadable
        }
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
        guard let root = try? HostHooksMergeEngine.parseRoot(data) else { return .occupied }
        return inspectionState(of: root)
    }

    static func inspectionState(of root: [String: Any]) -> InspectionState {
        let located = HostHooksMergeEngine.locateFingerprintedHooks(
            in: root,
            descriptor: wiringDescriptor
        )
        guard located.isEmpty == false else { return .absentFile }

        var allCurrent = true
        var hasStaleLegacy = false
        var hasNonCurrentGuard = false
        for item in located {
            if let itemMatcher = item.matcher,
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
            let present = Set(located.compactMap { $0.matcher })
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

}

enum ClaudeSettingsMergeError: Error, Equatable {
    case unreadable
    /// `merge` refused occupied settings without `force`. Setup surfaces this
    /// as a failed host write; the user reruns with `--force`.
    case occupiedWithoutForce
}
