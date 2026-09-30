import Foundation
import RVDomain

/// Merge / inspect / uninstall for `$HOME/.gemini/config/hooks.json`.
/// Global Antigravity hooks file (verified: settings.json embedding does not
/// load). Command is `python3` on the exclusive adapter; baked rv stays in
/// `RV_BINARY=` so `HostAdapterInstallation.inspect` can require sibling
/// `rv-cli` for `.wired`. Occupied is a foreign/tampered `rv-guard.py`.
///
/// Round-trip, strip/insert/uninstall, and locate delegate to
/// `HostHooksMergeEngine` via `wiringDescriptor`; inspection (occupancy,
/// matcher coverage) stays here over the engine's locate.
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

    static func adapterPath(hooksPath: String) -> String {
        (hooksPath as NSString).deletingLastPathComponent + "/hooks/rv-guard.py"
    }

    static func hookCommand(rvPath: String, adapterPath: String) -> String {
        "RV_BINARY=\(rvPath) python3 \(adapterPath)"
    }

    static func isFingerprinted(command: String) -> Bool {
        command.contains(fingerprint)
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
        guard command.hasPrefix(envPrefix) else { return nil }
        let rest = command.dropFirst(envPrefix.count)
        guard let space = rest.firstIndex(of: " ") else { return nil }
        let path = String(rest[..<space])
        return path.hasPrefix("/") ? path : nil
    }

    static func matchesCurrentHook(_ hook: JSONValue) -> Bool {
        guard let type = hook["type"]?.string, type == hookType,
              let command = hook["command"]?.string,
              let path = bakedRvPath(in: command),
              path.hasPrefix("/"),
              let adapter = adapterPath(in: command),
              adapter.hasPrefix("/"),
              adapter.hasSuffix("/hooks/rv-guard.py"),
              hook["timeout"]?.int == timeout
        else {
            return false
        }
        return command == hookCommand(rvPath: path, adapterPath: adapter)
    }

    static func isFingerprintedHook(_ hook: JSONValue) -> Bool {
        HostHooksMergeEngine.isFingerprintedHook(hook, descriptor: wiringDescriptor)
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

    static func rvEntry(rvPath: String, adapterPath: String, matcher: String) -> JSONValue {
        .object([
            "matcher": .string(matcher),
            "hooks": .array([
                HostHooksMergeEngine.hookValue(
                    hookEntry(rvPath: rvPath, adapterPath: adapterPath)
                ),
            ]),
        ])
    }

    static func hasFileToolMatchers(in root: [String: JSONValue]) -> Bool {
        let present = Set(
            HostHooksMergeEngine.locateFingerprintedHooks(in: root, descriptor: wiringDescriptor)
                .compactMap { $0.matcher }
        )
        return Set(fileMatchers).isSubset(of: present)
    }

    /// Frozen `HostWiring` boundary: bridges its untyped root onto `JSONValue`.
    static func hasFileToolMatchers(in root: [String: Any]) -> Bool {
        guard let typed = HostHooksMergeEngine.typedRoot(from: root) else {
            return false
        }
        return hasFileToolMatchers(in: typed)
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
            return try HostHooksMergeEngine.merge(
                existingData: existingData,
                descriptor: wiringDescriptor,
                context: HookCommandContext(rvPath: rvPath, adapterPath: adapterPath),
                willMerge: { root in
                    if force == false, inspectionState(of: root) == .occupied {
                        throw AntigravityHooksMergeError.occupiedWithoutForce
                    }
                }
            )
        } catch let error as AntigravityHooksMergeError {
            throw error
        } catch {
            throw AntigravityHooksMergeError.unreadable
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
            throw AntigravityHooksMergeError.unreadable
        }
    }

    enum InspectionState: Equatable {
        case absentFile
        case occupied
        /// Current command but missing matchers. Setup rewrites without `--force`.
        case outdated
        case wired(bakedPath: String)
    }

    static func inspectionState(of data: Data?) -> InspectionState {
        guard let data else { return .absentFile }
        guard let root = try? HostHooksMergeEngine.parseRoot(data) else { return .occupied }
        return inspectionState(of: root)
    }

    static func inspectionState(of root: [String: JSONValue]) -> InspectionState {
        let located = HostHooksMergeEngine.locateFingerprintedHooks(
            in: root,
            descriptor: wiringDescriptor
        )
        guard located.isEmpty == false else { return .absentFile }

        let want = matchers
        let allCurrent = located.allSatisfy { item in
            guard let itemMatcher = item.matcher,
                  want.contains(itemMatcher),
                  matchesCurrentHook(item.hook)
            else {
                return false
            }
            return true
        }
        guard allCurrent else { return .occupied }

        guard let bakedPath = located.compactMap({
            bakedRvPath(in: $0.hook["command"]?.string ?? "")
        }).first
        else {
            return .occupied
        }
        let present = Set(located.compactMap { $0.matcher })
        if Set(want).isSubset(of: present) {
            return .wired(bakedPath: bakedPath)
        }
        return .outdated
    }
}

enum AntigravityHooksMergeError: Error, Equatable {
    case unreadable
    /// `merge` refused occupied hooks without `force`. Setup surfaces this
    /// as `SetupError.hostHookOccupiedNeedsForce`; the user reruns with `--force`.
    case occupiedWithoutForce
}
