import Foundation
import RVDomain

/// Merge / inspect / uninstall for `$HOME/.claude/settings.json` (REQ-012..015).
/// Command is `python3` on the exclusive adapter; baked rv stays in `RV_BINARY=`
/// so `HostAdapterInstallation.inspect` can require sibling `rv-cli` for `.wired`.
/// Occupied is a foreign/tampered `rv-guard.py` that is not current. Stale
/// `hook --host claude` is outdated rv: setup rewrites without `--force`.
///
/// Round-trip, strip/insert/uninstall, and locate delegate to
/// `HostHooksMergeEngine` via `wiringDescriptor`; merge/inspect policy
/// delegates to `SettingsMergePolicy` via `mergeDescriptor`, with the
/// stale-legacy arm as descriptor data.
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

    static let mergeDescriptor = SettingsMergeDescriptor(
        wiring: wiringDescriptor,
        matchers: matchers,
        fileMatchers: fileMatchers,
        hookType: hookType,
        timeout: timeout,
        fingerprint: fingerprint,
        legacyFingerprint: fingerprintLegacy
    )

    static func adapterPath(settingsPath: String) -> String {
        SettingsMergePolicy.adapterPath(configPath: settingsPath, descriptor: mergeDescriptor)
    }

    static func hookCommand(rvPath: String, adapterPath: String) -> String {
        SettingsMergePolicy.hookCommand(rvPath: rvPath, adapterPath: adapterPath)
    }

    static func isFingerprinted(command: String) -> Bool {
        SettingsMergePolicy.isFingerprinted(command: command, descriptor: mergeDescriptor)
    }

    static func adapterPath(in command: String) -> String? {
        SettingsMergePolicy.adapterPath(in: command)
    }

    static func bakedRvPath(in command: String) -> String? {
        SettingsMergePolicy.bakedRvPath(in: command, descriptor: mergeDescriptor)
    }

    static func matchesCurrentHook(_ hook: JSONValue) -> Bool {
        SettingsMergePolicy.matchesCurrentHook(hook, descriptor: mergeDescriptor)
    }

    static func isFingerprintedHook(_ hook: JSONValue) -> Bool {
        SettingsMergePolicy.isFingerprintedHook(hook, descriptor: mergeDescriptor)
    }

    /// v1 `…/rv hook --host claude` is our stale command, not a foreign guard.
    static func isStaleLegacyHook(_ hook: JSONValue) -> Bool {
        SettingsMergePolicy.isStaleLegacyHook(hook, descriptor: mergeDescriptor)
    }

    static func hookEntry(rvPath: String, adapterPath: String) -> HookEntry {
        SettingsMergePolicy.hookEntry(
            rvPath: rvPath,
            adapterPath: adapterPath,
            descriptor: mergeDescriptor
        )
    }

    static func rvEntry(rvPath: String, adapterPath: String, matcher: String) -> JSONValue {
        SettingsMergePolicy.rvEntry(
            rvPath: rvPath,
            adapterPath: adapterPath,
            matcher: matcher,
            descriptor: mergeDescriptor
        )
    }

    static func hasFileToolMatchers(in root: [String: JSONValue]) -> Bool {
        SettingsMergePolicy.hasFileToolMatchers(in: root, descriptor: mergeDescriptor)
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
            return try SettingsMergePolicy.merge(
                existingData: existingData,
                descriptor: mergeDescriptor,
                rvPath: rvPath,
                adapterPath: adapterPath,
                force: force
            )
        } catch SettingsMergeError.occupiedWithoutForce {
            throw ClaudeSettingsMergeError.occupiedWithoutForce
        } catch {
            throw ClaudeSettingsMergeError.unreadable
        }
    }

    /// Strips rv-fingerprinted hooks. Returns `nil` when the file should be removed.
    static func uninstall(existingData: Data) throws -> Data? {
        do {
            return try SettingsMergePolicy.uninstall(
                existingData: existingData,
                descriptor: mergeDescriptor
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

        init(_ shared: SettingsMergePolicy.InspectionState) {
            switch shared {
            case .absentFile:
                self = .absentFile
            case .occupied:
                self = .occupied
            case .outdated:
                self = .outdated
            case .wired(let bakedPath):
                self = .wired(bakedPath: bakedPath)
            }
        }
    }

    static func inspectionState(of data: Data?) -> InspectionState {
        InspectionState(SettingsMergePolicy.inspectionState(of: data, descriptor: mergeDescriptor))
    }

    static func inspectionState(of root: [String: JSONValue]) -> InspectionState {
        InspectionState(SettingsMergePolicy.inspectionState(of: root, descriptor: mergeDescriptor))
    }
}

enum ClaudeSettingsMergeError: Error, Sendable, Equatable {
    case unreadable
    /// `merge` refused occupied settings without `force`. Setup surfaces this
    /// as `SetupError.hostHookOccupiedNeedsForce`; the user reruns with `--force`.
    case occupiedWithoutForce
}
