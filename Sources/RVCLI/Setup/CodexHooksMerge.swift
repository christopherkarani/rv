import Foundation
import RVDomain

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
    static let timeout = 18
    static let statusMessage = "RV"

    static let wiringDescriptor = HostWiringDescriptor(
        layout: .nested(hooksRootKey: hooksRootKey, listKey: preToolUseKey),
        matchers: [matcher],
        hookType: hookType,
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
        guard let type = hook["type"]?.string, type == hookType,
              let command = hook["command"]?.string,
              isCurrentCommand(command, adapterPath: adapterPath),
              hook["timeout"]?.int == timeout,
              hook["statusMessage"]?.string == statusMessage
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
            type: hookType,
            failClosed: nil,
            statusMessage: statusMessage
        )
    }

    static func rvEntry(interpreter: String, adapterPath: String) -> JSONValue {
        .object([
            "matcher": .string(matcher),
            "hooks": .array([
                HostHooksMergeEngine.hookValue(hookEntry(interpreter: interpreter, adapterPath: adapterPath)),
            ]),
        ])
    }

    /// Returns merged hooks bytes and whether content changed.
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
