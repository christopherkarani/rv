import Foundation
import RVDomain

/// Merge / inspect / uninstall for `$HOME/.gemini/config/hooks.json`.
/// Global Antigravity hooks file (verified: settings.json embedding does not
/// load). Command is `python3` on the exclusive adapter; baked rv stays in
/// `RV_BINARY=` so `HostAdapterInstallation.inspect` can require sibling
/// `rv-cli` for `.wired`. Occupied is a foreign/tampered `rv-guard.py`.
///
/// Round-trip, strip/insert/uninstall, and locate delegate to
/// `HostHooksMergeEngine` via `wiringDescriptor`; merge/inspect policy
/// delegates to `SettingsMergePolicy` via `mergeDescriptor` (no
/// stale-legacy arm).
enum AntigravityHooksMerge {
    static let hooksFileName = "hooks.json"
    static let hookName = "rv-guard"
    static let preToolUseKey = "PreToolUse"
    static let fingerprint = "rv-guard.py"
    static let matcher = "run_command"
    static let fileMatchers = [
        "view_file", "write_to_file", "replace_file_content", "multi_replace_file_content",
    ]
    static var matchers: [String] { [matcher] + fileMatchers }
    static let hookType = "command"
    static let timeout = 10

    static let wiringDescriptor = HostWiringDescriptor(
        layout: .grouped(hookName: hookName, listKey: preToolUseKey),
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
        legacyFingerprint: nil
    )

    static func adapterPath(hooksPath: String) -> String {
        SettingsMergePolicy.adapterPath(configPath: hooksPath, descriptor: mergeDescriptor)
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

    /// Returns merged hooks bytes and whether content changed.
    /// Setup writes through `HostWiring.applyAntigravity`.
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
            throw AntigravityHooksMergeError.occupiedWithoutForce
        } catch {
            throw AntigravityHooksMergeError.unreadable
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
            throw AntigravityHooksMergeError.unreadable
        }
    }

    enum InspectionState: Equatable {
        case absentFile
        case occupied
        /// Current command but missing matchers. Setup rewrites without `--force`.
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

enum AntigravityHooksMergeError: Error, Equatable {
    case unreadable
    /// `merge` refused occupied hooks without `force`. Setup surfaces this
    /// as `SetupError.hostHookOccupiedNeedsForce`; the user reruns with `--force`.
    case occupiedWithoutForce
}
