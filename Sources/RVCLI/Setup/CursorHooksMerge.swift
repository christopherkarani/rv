import Foundation
import RVDomain

/// Merge / inspect / uninstall for `$HOME/.cursor/hooks.json`.
/// Occupancy of the setup slot is the exclusive `rv-guard.py`; this merge only
/// registers that adapter under official `beforeShellExecution`,
/// `preToolUse` and `beforeReadFile` with
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
    static let beforeReadFileKey = "beforeReadFile"
    static let fingerprint = "rv-guard.py"
    static let timeout = 18
    static let schemaVersion = 1

    static let wiringDescriptor = HostWiringDescriptor(
        layout: .flat(
            hooksRootKey: hooksRootKey,
            listKeys: [beforeShellKey, preToolUseKey, beforeReadFileKey],
            versionKey: versionKey,
            schemaVersion: schemaVersion
        ),
        matchers: [],
        hookType: nil,
        isFingerprintedCommand: { isFingerprinted(command: $0) },
        buildEntry: { context, _ in
            hookEntry(interpreter: context.interpreter, adapterPath: context.adapterPath)
        }
    )

    /// Paths are shell-quoted when needed (a HOME with a space): the host
    /// runs the command through a shell. See `AdapterCommand`.
    static func hookCommand(interpreter: String, adapterPath: String) -> String {
        AdapterCommand.render(interpreter: interpreter, adapterPath: adapterPath)
    }

    static func isFingerprinted(command: String) -> Bool {
        command.contains(fingerprint)
    }

    static func adapterPath(in command: String) -> String? {
        guard isFingerprinted(command: command) else { return nil }
        return AdapterCommand.adapterPath(in: command)
    }

    /// rv's current command for `adapterPath`, any absolute interpreter.
    /// The earlier `python3 <adapter>` form is not current: setup rewrites it.
    static func isCurrentCommand(_ command: String, adapterPath: String) -> Bool {
        guard let interpreter = AdapterCommand.bakedInterpreter(in: Substring(command)) else { return false }
        return command == hookCommand(interpreter: interpreter, adapterPath: adapterPath)
    }

    static func matchesCurrentHook(_ hook: JSONValue, adapterPath: String) -> Bool {
        guard let command = hook["command"]?.string,
              isCurrentCommand(command, adapterPath: adapterPath),
              hook["timeout"]?.int == timeout,
              hook["failClosed"]?.bool == true
        else {
            return false
        }
        return true
    }

    static func isFingerprintedHook(_ hook: JSONValue) -> Bool {
        HostHooksMergeEngine.isFingerprintedHook(hook, descriptor: wiringDescriptor)
    }

    static func hookEntry(interpreter: String, adapterPath: String) -> HookEntry {
        HookEntry(
            command: hookCommand(interpreter: interpreter, adapterPath: adapterPath),
            timeout: timeout,
            type: nil,
            failClosed: true,
            statusMessage: nil
        )
    }

    static func rvEntry(interpreter: String, adapterPath: String) -> JSONValue {
        HostHooksMergeEngine.hookValue(hookEntry(interpreter: interpreter, adapterPath: adapterPath))
    }

    /// Returns merged hooks bytes and whether content changed.
    /// Setup writes through `HostWiring.applyCursor`.
    static func merge(
        existingData: Data?,
        interpreter: String,
        adapterPath: String
    ) throws -> (data: Data, wrote: Bool) {
        do {
            return try HostHooksMergeEngine.merge(
                existingData: existingData,
                descriptor: wiringDescriptor,
                context: HookCommandContext(rvPath: nil, interpreter: interpreter, adapterPath: adapterPath)
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

    static func hasFileToolEntry(in root: [String: JSONValue]) -> Bool {
        HostHooksMergeEngine.locateFingerprintedHooks(in: root, descriptor: wiringDescriptor)
            .contains { $0.listKey == preToolUseKey }
    }
}

enum CursorHooksMergeError: Error, Equatable {
    case unreadable
}
