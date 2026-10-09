import Foundation
import RVDomain

/// Per-host data parameterizing `SettingsMergePolicy`. Per-host behavior
/// differences live here; shared occupancy-trap merge/inspect policy lives in
/// the module. Claude carries its v1 stale-legacy marker; Antigravity has no
/// legacy arm (`legacyFingerprint == nil` reads as never-stale).
struct SettingsMergeDescriptor: Sendable {
    /// Hook-list shape plus locate/strip/insert wiring for the engine.
    let wiring: HostWiringDescriptor
    let matchers: [String]
    let fileMatchers: [String]
    let hookType: String
    let timeout: Int
    /// Current-guard marker (`rv-guard.py`); also the adapter file name.
    let fingerprint: String
    /// Superseded own-command marker, treated as outdated rather than
    /// occupied. Claude-only; nil disables the stale-legacy arm.
    let legacyFingerprint: String?
}

/// Deep module owning the occupancy-trap merge/inspect policy shared by the
/// Claude and Antigravity hook merges. Per-host enums keep their entry
/// points, inspection/error types, and constants, and delegate here with
/// their `mergeDescriptor`.
///
/// Round-trip, strip/insert/uninstall, and locate still delegate to
/// `HostHooksMergeEngine` via the descriptor's wiring.
enum SettingsMergePolicy {
    enum InspectionState: Equatable, Sendable {
        case absentFile
        case occupied
        /// Current command but missing matchers, or our own superseded
        /// command (Claude stale-legacy). Setup rewrites without `--force`.
        case outdated
        case wired(bakedPath: String)
    }

    /// The single `RV_BINARY=` hook-command construction site.
    static func hookCommand(rvPath: String, adapterPath: String) -> String {
        "RV_BINARY=\(rvPath) python3 \(adapterPath)"
    }

    /// Exclusive adapter location next to the host config file.
    static func adapterPath(configPath: String, descriptor: SettingsMergeDescriptor) -> String {
        (configPath as NSString).deletingLastPathComponent + "/hooks/" + descriptor.fingerprint
    }

    static func isFingerprinted(command: String, descriptor: SettingsMergeDescriptor) -> Bool {
        command.contains(descriptor.fingerprint)
            || (descriptor.legacyFingerprint.map { command.contains($0) } ?? false)
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

    static func bakedRvPath(in command: String, descriptor: SettingsMergeDescriptor) -> String? {
        let envPrefix = "RV_BINARY="
        if command.hasPrefix(envPrefix) {
            let rest = command.dropFirst(envPrefix.count)
            guard let space = rest.firstIndex(of: " ") else { return nil }
            let path = String(rest[..<space])
            return path.hasPrefix("/") && path.isEmpty == false ? path : nil
        }
        guard let legacy = descriptor.legacyFingerprint else { return nil }
        let suffix = " " + legacy
        guard command.hasSuffix(suffix) else { return nil }
        let path = String(command.dropLast(suffix.count))
        guard path.hasPrefix("python3 ") == false, path.contains(" python3 ") == false else {
            return nil
        }
        return path.hasPrefix("/") && path.isEmpty == false ? path : nil
    }

    static func matchesCurrentHook(
        _ hook: JSONValue,
        descriptor: SettingsMergeDescriptor
    ) -> Bool {
        guard let type = hook["type"]?.string, type == descriptor.hookType,
              let command = hook["command"]?.string,
              let path = bakedRvPath(in: command, descriptor: descriptor),
              path.hasPrefix("/"),
              let adapter = adapterPath(in: command),
              adapter.hasPrefix("/"),
              adapter.hasSuffix("/hooks/" + descriptor.fingerprint),
              hook["timeout"]?.int == descriptor.timeout
        else {
            return false
        }
        return command == hookCommand(rvPath: path, adapterPath: adapter)
    }

    static func isFingerprintedHook(
        _ hook: JSONValue,
        descriptor: SettingsMergeDescriptor
    ) -> Bool {
        HostHooksMergeEngine.isFingerprintedHook(hook, descriptor: descriptor.wiring)
    }

    /// Our own superseded command, not a foreign guard. Hosts without a
    /// legacy marker (Antigravity) never report stale-legacy.
    static func isStaleLegacyHook(
        _ hook: JSONValue,
        descriptor: SettingsMergeDescriptor
    ) -> Bool {
        guard let legacy = descriptor.legacyFingerprint,
              let type = hook["type"]?.string, type == descriptor.hookType,
              let command = hook["command"]?.string
        else {
            return false
        }
        return command.contains(legacy) && command.contains(descriptor.fingerprint) == false
    }

    static func hookEntry(
        rvPath: String,
        adapterPath: String,
        descriptor: SettingsMergeDescriptor
    ) -> HookEntry {
        HookEntry(
            command: hookCommand(rvPath: rvPath, adapterPath: adapterPath),
            timeout: descriptor.timeout,
            type: descriptor.hookType,
            failClosed: nil,
            statusMessage: nil
        )
    }

    static func rvEntry(
        rvPath: String,
        adapterPath: String,
        matcher: String,
        descriptor: SettingsMergeDescriptor
    ) -> JSONValue {
        .object([
            "matcher": .string(matcher),
            "hooks": .array([
                HostHooksMergeEngine.hookValue(
                    hookEntry(rvPath: rvPath, adapterPath: adapterPath, descriptor: descriptor)
                ),
            ]),
        ])
    }

    static func hasFileToolMatchers(
        in root: [String: JSONValue],
        descriptor: SettingsMergeDescriptor
    ) -> Bool {
        let present = Set(
            HostHooksMergeEngine.locateFingerprintedHooks(in: root, descriptor: descriptor.wiring)
                .compactMap { $0.matcher }
        )
        return Set(descriptor.fileMatchers).isSubset(of: present)
    }

    /// Returns merged hook-file bytes and whether content changed.
    /// Refuses occupied roots without `force`; outdated roots rewrite.
    static func merge(
        existingData: Data?,
        descriptor: SettingsMergeDescriptor,
        rvPath: String,
        adapterPath: String,
        force: Bool
    ) throws(SettingsMergeError) -> (data: Data, wrote: Bool) {
        do {
            return try HostHooksMergeEngine.merge(
                existingData: existingData,
                descriptor: descriptor.wiring,
                context: HookCommandContext(rvPath: rvPath, adapterPath: adapterPath),
                willMerge: { root in
                    if force == false, inspectionState(of: root, descriptor: descriptor) == .occupied {
                        throw SettingsMergeError.occupiedWithoutForce
                    }
                }
            )
        } catch let error as SettingsMergeError {
            throw error
        } catch {
            throw SettingsMergeError.unreadable
        }
    }

    /// Strips rv-fingerprinted hooks. Returns `nil` when the file should be removed.
    static func uninstall(
        existingData: Data,
        descriptor: SettingsMergeDescriptor
    ) throws(SettingsMergeError) -> Data? {
        do {
            return try HostHooksMergeEngine.uninstall(
                existingData: existingData,
                descriptor: descriptor.wiring
            )
        } catch {
            throw SettingsMergeError.unreadable
        }
    }

    static func inspectionState(
        of data: Data?,
        descriptor: SettingsMergeDescriptor
    ) -> InspectionState {
        guard let data else { return .absentFile }
        guard let root = try? HostHooksMergeEngine.parseRoot(data) else { return .occupied }
        return inspectionState(of: root, descriptor: descriptor)
    }

    static func inspectionState(
        of root: [String: JSONValue],
        descriptor: SettingsMergeDescriptor
    ) -> InspectionState {
        let located = HostHooksMergeEngine.locateFingerprintedHooks(
            in: root,
            descriptor: descriptor.wiring
        )
        guard located.isEmpty == false else { return .absentFile }

        var allCurrent = true
        var hasStaleLegacy = false
        var hasNonCurrentGuard = false
        for item in located {
            if let itemMatcher = item.matcher,
               descriptor.matchers.contains(itemMatcher),
               matchesCurrentHook(item.hook, descriptor: descriptor)
            {
                continue
            }
            allCurrent = false
            if isStaleLegacyHook(item.hook, descriptor: descriptor) {
                hasStaleLegacy = true
            } else {
                hasNonCurrentGuard = true
            }
        }

        if allCurrent {
            guard let bakedPath = located.compactMap({
                bakedRvPath(in: $0.hook["command"]?.string ?? "", descriptor: descriptor)
            }).first
            else {
                return .occupied
            }
            let present = Set(located.compactMap { $0.matcher })
            if Set(descriptor.matchers).isSubset(of: present) {
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

enum SettingsMergeError: Error, Sendable, Equatable {
    case unreadable
    /// `merge` refused occupied hooks without `force`. Per-host merges map
    /// this to their own occupied error; setup surfaces it as
    /// `SetupError.hostHookOccupiedNeedsForce`.
    case occupiedWithoutForce
}
