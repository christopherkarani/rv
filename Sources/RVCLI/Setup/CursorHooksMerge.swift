import Foundation

/// Merge / inspect / uninstall for `$HOME/.cursor/hooks.json`.
/// Occupancy of the setup slot is the exclusive `rv-guard.py`; this merge only
/// registers that adapter under official `beforeShellExecution` with
/// `failClosed: true` and strips the fingerprint.
///
/// Round-trip, strip/insert/uninstall delegate to `HostHooksMergeEngine` via
/// `wiringDescriptor`.
enum CursorHooksMerge {
    static let hooksFileName = "hooks.json"
    static let versionKey = "version"
    static let hooksRootKey = "hooks"
    static let beforeShellKey = "beforeShellExecution"
    static let preToolUseKey = "preToolUse"
    static let fingerprint = "rv-guard.py"
    static let timeout = 5
    static let schemaVersion = 1

    static let wiringDescriptor = HostWiringDescriptor(
        layout: .flat(
            hooksRootKey: hooksRootKey,
            listKeys: [beforeShellKey, preToolUseKey],
            versionKey: versionKey,
            schemaVersion: schemaVersion
        ),
        matchers: [],
        hookType: nil,
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
        HostHooksMergeEngine.isFingerprintedHook(hook, descriptor: wiringDescriptor)
    }

    static func hookEntry(adapterPath: String) -> HookEntry {
        HookEntry(
            command: hookCommand(adapterPath: adapterPath),
            timeout: timeout,
            type: nil,
            failClosed: true,
            statusMessage: nil
        )
    }

    static func rvEntry(adapterPath: String) -> [String: Any] {
        HostHooksMergeEngine.hookDictionary(hookEntry(adapterPath: adapterPath))
    }

    /// Returns merged hooks bytes and whether content changed.
    /// Setup writes through `HostWiring.applyCursor`.
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
            throw CursorHooksMergeError.unreadable
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
            throw CursorHooksMergeError.unreadable
        }
    }

    static func hasFileToolEntry(in root: [String: Any]) -> Bool {
        HostHooksMergeEngine.locateFingerprintedHooks(in: root, descriptor: wiringDescriptor)
            .contains { $0.listKey == preToolUseKey }
    }
}

enum CursorHooksMergeError: Error, Equatable {
    case unreadable
}
