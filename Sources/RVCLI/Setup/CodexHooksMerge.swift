import Foundation

/// Merge / inspect / uninstall for `$HOME/.codex/hooks.json`.
/// Occupancy of the setup slot is the exclusive `rv-guard.py`; this merge only
/// registers that adapter under PreToolUse / Bash and strips the fingerprint.
///
/// Round-trip, strip/insert/uninstall delegate to `HostHooksMergeEngine` via
/// `wiringDescriptor`.
enum CodexHooksMerge {
    static let hooksFileName = "hooks.json"
    static let hooksRootKey = "hooks"
    static let preToolUseKey = "PreToolUse"
    static let fingerprint = "rv-guard.py"
    static let matcher = "Bash"
    static let hookType = "command"
    static let timeout = 5
    static let statusMessage = "RV"

    static let wiringDescriptor = HostWiringDescriptor(
        layout: .nested(hooksRootKey: hooksRootKey, listKey: preToolUseKey),
        matchers: [matcher],
        hookType: hookType,
        isFingerprintedCommand: { isFingerprinted(command: $0) },
        buildEntry: { context, _ in
            hookEntry(adapterPath: context.adapterPath)
        }
    )

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
        HostHooksMergeEngine.isFingerprintedHook(hook, descriptor: wiringDescriptor)
    }

    static func hookEntry(adapterPath: String) -> HookEntry {
        HookEntry(
            command: hookCommand(adapterPath: adapterPath),
            timeout: timeout,
            type: hookType,
            failClosed: nil,
            statusMessage: statusMessage
        )
    }

    static func rvEntry(adapterPath: String) -> [String: Any] {
        [
            "matcher": matcher,
            "hooks": [
                HostHooksMergeEngine.hookDictionary(hookEntry(adapterPath: adapterPath)),
            ],
        ]
    }

    /// Returns merged hooks bytes and whether content changed.
    static func merge(
        existingData: Data?,
        adapterPath: String
    ) throws -> (data: Data, wrote: Bool) {
        do {
            return try HostHooksMergeEngine.merge(
                existingData: existingData,
                descriptor: wiringDescriptor,
                context: HookCommandContext(rvPath: nil, adapterPath: adapterPath)
            )
        } catch {
            throw CodexHooksMergeError.unreadable
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
            throw CodexHooksMergeError.unreadable
        }
    }
}

enum CodexHooksMergeError: Error, Equatable {
    case unreadable
}
