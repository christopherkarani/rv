import Foundation

/// Typed hook entry; host files build these instead of `[String: Any]` literals.
/// The engine serializes to the exact historical dict shapes (T2).
struct HookEntry: Equatable, Sendable {
    var command: String
    var timeout: Int
    /// Nested/grouped layouts (`"command"`); nil for flat layouts (Cursor has no `type` key).
    var type: String? = nil
    /// Cursor only.
    var failClosed: Bool? = nil
    /// Codex only.
    var statusMessage: String? = nil
}

/// Per-call inputs needed to build hook entries.
struct HookCommandContext: Equatable, Sendable {
    /// Claude/Antigravity bake `RV_BINARY=<rvPath>`; other hosts leave this nil.
    var rvPath: String?
    var adapterPath: String
}

/// Hook-list JSON shapes the engine drives.
enum HooksLayout: Equatable, Sendable {
    /// `{ root: { list: [{ matcher, hooks: [hook] }] } }` (Claude, Codex).
    case nested(hooksRootKey: String, listKey: String)
    /// `{ root: { key: [hook] } }` per key, plus an optional schema version (Cursor).
    case flat(hooksRootKey: String, listKeys: [String], versionKey: String?, schemaVersion: Int?)
    /// `{ hookName: { enabled: true, list: [{ matcher, hooks: [hook] }] } }`
    /// (Antigravity). One named hook owns the matcher groups.
    case grouped(hookName: String, listKey: String)
}

/// Per-host wiring descriptor: shape data plus small predicates/builders.
/// New hook entries are typed (`HookEntry`); raw dicts cross the boundary only
/// where frozen per-host APIs (`matchesCurrentHook`, `rvEntry`, inspection)
/// require them.
struct HostWiringDescriptor: Sendable {
    var layout: HooksLayout
    /// Nested/grouped insert matchers, in append order (Claude 4, Codex 1, Antigravity 5). Unused for flat.
    var matchers: [String]
    /// Required hook `type` value; nil skips the check (flat layouts).
    var hookType: String?
    var isFingerprintedCommand: @Sendable (String) -> Bool
    /// Builds one hook entry; the matcher is non-nil for nested/grouped layouts.
    var buildEntry: @Sendable (HookCommandContext, String?) -> HookEntry
}

/// One fingerprinted hook found in a parsed root.
struct LocatedHook {
    /// Nested/grouped entry matcher; nil for flat layouts.
    var matcher: String?
    /// The list key the hook was found under.
    var listKey: String
    var hook: [String: Any]
}

enum HostHooksMergeError: Error, Equatable {
    case unreadable
}

/// Deep module owning hook-list JSON round-trip, strip/insert/uninstall, and
/// locate for the Claude / Codex / Cursor / Antigravity setup merges (T2).
///
/// OpenCode (plugin list) and Grok (exclusive render) do not share the
/// hook-list shape, so they stay out of the engine per the GUD-001 fallback.
/// Claude inspection (occupancy, stale legacy, matcher coverage) stays in
/// `ClaudeSettingsMerge`; Antigravity inspection stays in
/// `AntigravitySettingsMerge`; both are implemented over `locateFingerprintedHooks`.
/// Follow-up per GUD-002: adopt T1's typed-JSON value here once T1 lands.
enum HostHooksMergeEngine {
    /// Returns merged bytes and whether content changed.
    /// `willMerge` runs after parsing, before mutation (Claude/Antigravity occupancy trap).
    static func merge(
        existingData: Data?,
        descriptor: HostWiringDescriptor,
        context: HookCommandContext,
        willMerge: (([String: Any]) -> Void)? = nil
    ) throws -> (data: Data, wrote: Bool) {
        let root = try parseRoot(existingData)
        willMerge?(root)
        var next = stripFingerprinted(from: root, descriptor: descriptor)
        next = insertEntries(into: next, descriptor: descriptor, context: context)
        let data = try encode(next)
        return (data, existingData != data)
    }

    /// Strips fingerprinted hooks. Returns `nil` when the file should be removed
    /// (empty, or version-key-only for versioned flat layouts).
    static func uninstall(
        existingData: Data,
        descriptor: HostWiringDescriptor
    ) throws -> Data? {
        let root = try parseRoot(existingData)
        let stripped = stripFingerprinted(from: root, descriptor: descriptor)
        if stripped.isEmpty {
            return nil
        }
        if case .flat(_, _, let versionKey, _) = descriptor.layout,
           let versionKey,
           stripped.keys.count == 1,
           stripped[versionKey] != nil
        {
            return nil
        }
        return try encode(stripped)
    }

    static func locateFingerprintedHooks(
        in root: [String: Any],
        descriptor: HostWiringDescriptor
    ) -> [LocatedHook] {
        switch descriptor.layout {
        case .nested(let hooksRootKey, let listKey):
            guard let hooksRoot = root[hooksRootKey] as? [String: Any],
                  let list = hooksRoot[listKey] as? [[String: Any]]
            else {
                return []
            }
            return locate(in: list, listKey: listKey, descriptor: descriptor)
        case .grouped(let hookName, let listKey):
            guard let group = root[hookName] as? [String: Any],
                  let list = group[listKey] as? [[String: Any]]
            else {
                return []
            }
            return locate(in: list, listKey: listKey, descriptor: descriptor)
        case .flat(let hooksRootKey, let listKeys, _, _):
            guard let hooksRoot = root[hooksRootKey] as? [String: Any] else {
                return []
            }
            var located: [LocatedHook] = []
            for key in listKeys {
                guard let hooks = hooksRoot[key] as? [[String: Any]] else { continue }
                for hook in hooks where isFingerprintedHook(hook, descriptor: descriptor) {
                    located.append(LocatedHook(matcher: nil, listKey: key, hook: hook))
                }
            }
            return located
        }
    }

    private static func locate(
        in list: [[String: Any]],
        listKey: String,
        descriptor: HostWiringDescriptor
    ) -> [LocatedHook] {
        var located: [LocatedHook] = []
        for entry in list {
            guard let hooks = entry["hooks"] as? [[String: Any]] else { continue }
            for hook in hooks where isFingerprintedHook(hook, descriptor: descriptor) {
                located.append(LocatedHook(
                    matcher: entry["matcher"] as? String,
                    listKey: listKey,
                    hook: hook
                ))
            }
        }
        return located
    }

    static func isFingerprintedHook(
        _ hook: [String: Any],
        descriptor: HostWiringDescriptor
    ) -> Bool {
        if let hookType = descriptor.hookType {
            guard (hook["type"] as? String) == hookType else {
                return false
            }
        }
        guard let command = hook["command"] as? String else {
            return false
        }
        return descriptor.isFingerprintedCommand(command)
    }

    static func stripFingerprinted(
        from root: [String: Any],
        descriptor: HostWiringDescriptor
    ) -> [String: Any] {
        switch descriptor.layout {
        case .nested(let hooksRootKey, let listKey):
            guard var hooksRoot = root[hooksRootKey] as? [String: Any],
                  let list = hooksRoot[listKey] as? [[String: Any]]
            else {
                return root
            }
            let nextEntries = stripGroups(in: list, descriptor: descriptor)
            if nextEntries.isEmpty {
                hooksRoot.removeValue(forKey: listKey)
            } else {
                hooksRoot[listKey] = nextEntries
            }
            var next = root
            if hooksRoot.isEmpty {
                next.removeValue(forKey: hooksRootKey)
            } else {
                next[hooksRootKey] = hooksRoot
            }
            return next
        case .grouped(let hookName, let listKey):
            guard var group = root[hookName] as? [String: Any],
                  let list = group[listKey] as? [[String: Any]]
            else {
                return root
            }
            let nextEntries = stripGroups(in: list, descriptor: descriptor)
            if nextEntries.isEmpty {
                group.removeValue(forKey: listKey)
            } else {
                group[listKey] = nextEntries
            }
            var next = root
            // Drop our named hook when only `enabled` (or nothing) remains;
            // foreign events under the same name keep the group alive.
            if group.keys.allSatisfy({ $0 == "enabled" }) {
                next.removeValue(forKey: hookName)
            } else {
                next[hookName] = group
            }
            return next
        case .flat(let hooksRootKey, let listKeys, _, _):
            guard var hooksRoot = root[hooksRootKey] as? [String: Any] else {
                return root
            }
            for key in listKeys {
                guard let entries = hooksRoot[key] as? [[String: Any]] else { continue }
                let kept = entries.filter {
                    isFingerprintedHook($0, descriptor: descriptor) == false
                }
                if kept.isEmpty {
                    hooksRoot.removeValue(forKey: key)
                } else {
                    hooksRoot[key] = kept
                }
            }
            var next = root
            if hooksRoot.isEmpty {
                next.removeValue(forKey: hooksRootKey)
            } else {
                next[hooksRootKey] = hooksRoot
            }
            return next
        }
    }

    private static func stripGroups(
        in list: [[String: Any]],
        descriptor: HostWiringDescriptor
    ) -> [[String: Any]] {
        var nextEntries: [[String: Any]] = []
        for var entry in list {
            guard var hooks = entry["hooks"] as? [[String: Any]] else {
                nextEntries.append(entry)
                continue
            }
            hooks.removeAll { isFingerprintedHook($0, descriptor: descriptor) }
            guard hooks.isEmpty == false else { continue }
            entry["hooks"] = hooks
            nextEntries.append(entry)
        }
        return nextEntries
    }

    static func insertEntries(
        into root: [String: Any],
        descriptor: HostWiringDescriptor,
        context: HookCommandContext
    ) -> [String: Any] {
        switch descriptor.layout {
        case .nested(let hooksRootKey, let listKey):
            var next = root
            var hooksRoot = next[hooksRootKey] as? [String: Any] ?? [:]
            var list = hooksRoot[listKey] as? [[String: Any]] ?? []
            for matcher in descriptor.matchers {
                list.append([
                    "matcher": matcher,
                    "hooks": [hookDictionary(descriptor.buildEntry(context, matcher))],
                ])
            }
            hooksRoot[listKey] = list
            next[hooksRootKey] = hooksRoot
            return next
        case .grouped(let hookName, let listKey):
            var next = root
            var group = next[hookName] as? [String: Any] ?? [:]
            var list = group[listKey] as? [[String: Any]] ?? []
            for matcher in descriptor.matchers {
                list.append([
                    "matcher": matcher,
                    "hooks": [hookDictionary(descriptor.buildEntry(context, matcher))],
                ])
            }
            group["enabled"] = true
            group[listKey] = list
            next[hookName] = group
            return next
        case .flat(let hooksRootKey, let listKeys, let versionKey, let schemaVersion):
            var next = root
            var hooksRoot = next[hooksRootKey] as? [String: Any] ?? [:]
            for key in listKeys {
                var list = hooksRoot[key] as? [[String: Any]] ?? []
                list.append(hookDictionary(descriptor.buildEntry(context, nil)))
                hooksRoot[key] = list
            }
            next[hooksRootKey] = hooksRoot
            if let versionKey, let schemaVersion, next[versionKey] == nil {
                next[versionKey] = schemaVersion
            }
            return next
        }
    }

    /// Serializes one typed entry to its historical dict shape.
    static func hookDictionary(_ entry: HookEntry) -> [String: Any] {
        var dict: [String: Any] = [
            "command": entry.command,
            "timeout": entry.timeout,
        ]
        if let type = entry.type {
            dict["type"] = type
        }
        if let failClosed = entry.failClosed {
            dict["failClosed"] = failClosed
        }
        if let statusMessage = entry.statusMessage {
            dict["statusMessage"] = statusMessage
        }
        return dict
    }

    static func parseRoot(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HostHooksMergeError.unreadable
        }
        return object
    }

    private static func encode(_ root: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw HostHooksMergeError.unreadable
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
    }
}
