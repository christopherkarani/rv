import Foundation
import RVDomain

/// Typed hook entry; host files build these instead of untyped literals.
/// The engine serializes to the exact historical JSON shapes (T2).
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
/// New hook entries are typed (`HookEntry`); parsed file content crosses the
/// boundary as `JSONValue`. Raw dicts survive only in the `HostWiring`
/// compat overloads, which bridge onto `JSONValue` at entry.
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
    var hook: JSONValue
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
/// `AntigravityHooksMerge`; both are implemented over `locateFingerprintedHooks`.
enum HostHooksMergeEngine {
    /// Returns merged bytes and whether content changed.
    /// `willMerge` runs after parsing, before mutation (Claude/Antigravity occupancy trap).
    static func merge(
        existingData: Data?,
        descriptor: HostWiringDescriptor,
        context: HookCommandContext,
        willMerge: (([String: JSONValue]) throws -> Void)? = nil
    ) throws -> (data: Data, wrote: Bool) {
        let root = try parseRoot(existingData)
        try willMerge?(root)
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
        in root: [String: JSONValue],
        descriptor: HostWiringDescriptor
    ) -> [LocatedHook] {
        switch descriptor.layout {
        case .nested(let hooksRootKey, let listKey):
            guard let list = root[hooksRootKey]?[listKey]?.asArray else {
                return []
            }
            return locate(in: list, listKey: listKey, descriptor: descriptor)
        case .grouped(let hookName, let listKey):
            guard let list = root[hookName]?[listKey]?.asArray else {
                return []
            }
            return locate(in: list, listKey: listKey, descriptor: descriptor)
        case .flat(let hooksRootKey, let listKeys, _, _):
            guard let hooksRoot = root[hooksRootKey]?.asObject else {
                return []
            }
            var located: [LocatedHook] = []
            for key in listKeys {
                guard let hooks = hooksRoot[key]?.asArray else { continue }
                for hook in hooks where isFingerprintedHook(hook, descriptor: descriptor) {
                    located.append(LocatedHook(matcher: nil, listKey: key, hook: hook))
                }
            }
            return located
        }
    }

    private static func locate(
        in list: [JSONValue],
        listKey: String,
        descriptor: HostWiringDescriptor
    ) -> [LocatedHook] {
        var located: [LocatedHook] = []
        for entry in list {
            guard let hooks = entry["hooks"]?.asArray else { continue }
            for hook in hooks where isFingerprintedHook(hook, descriptor: descriptor) {
                located.append(LocatedHook(
                    matcher: entry["matcher"]?.string,
                    listKey: listKey,
                    hook: hook
                ))
            }
        }
        return located
    }

    static func isFingerprintedHook(
        _ hook: JSONValue,
        descriptor: HostWiringDescriptor
    ) -> Bool {
        if let hookType = descriptor.hookType {
            guard hook["type"]?.string == hookType else {
                return false
            }
        }
        guard let command = hook["command"]?.string else {
            return false
        }
        return descriptor.isFingerprintedCommand(command)
    }

    static func stripFingerprinted(
        from root: [String: JSONValue],
        descriptor: HostWiringDescriptor
    ) -> [String: JSONValue] {
        switch descriptor.layout {
        case .nested(let hooksRootKey, let listKey):
            guard var hooksRoot = root[hooksRootKey]?.asObject,
                  let list = hooksRoot[listKey]?.asArray
            else {
                return root
            }
            let nextEntries = stripGroups(in: list, descriptor: descriptor)
            if nextEntries.isEmpty {
                hooksRoot.removeValue(forKey: listKey)
            } else {
                hooksRoot[listKey] = .array(nextEntries)
            }
            var next = root
            if hooksRoot.isEmpty {
                next.removeValue(forKey: hooksRootKey)
            } else {
                next[hooksRootKey] = .object(hooksRoot)
            }
            return next
        case .grouped(let hookName, let listKey):
            guard var group = root[hookName]?.asObject,
                  let list = group[listKey]?.asArray
            else {
                return root
            }
            let nextEntries = stripGroups(in: list, descriptor: descriptor)
            if nextEntries.isEmpty {
                group.removeValue(forKey: listKey)
            } else {
                group[listKey] = .array(nextEntries)
            }
            var next = root
            // Drop our named hook when only `enabled` (or nothing) remains;
            // foreign events under the same name keep the group alive.
            if group.keys.allSatisfy({ $0 == "enabled" }) {
                next.removeValue(forKey: hookName)
            } else {
                next[hookName] = .object(group)
            }
            return next
        case .flat(let hooksRootKey, let listKeys, _, _):
            guard var hooksRoot = root[hooksRootKey]?.asObject else {
                return root
            }
            for key in listKeys {
                guard let entries = hooksRoot[key]?.asArray else { continue }
                let kept = entries.filter {
                    isFingerprintedHook($0, descriptor: descriptor) == false
                }
                if kept.isEmpty {
                    hooksRoot.removeValue(forKey: key)
                } else {
                    hooksRoot[key] = .array(kept)
                }
            }
            var next = root
            if hooksRoot.isEmpty {
                next.removeValue(forKey: hooksRootKey)
            } else {
                next[hooksRootKey] = .object(hooksRoot)
            }
            return next
        }
    }

    private static func stripGroups(
        in list: [JSONValue],
        descriptor: HostWiringDescriptor
    ) -> [JSONValue] {
        var nextEntries: [JSONValue] = []
        for entry in list {
            guard var object = entry.asObject,
                  let hooks = object["hooks"]?.asArray
            else {
                nextEntries.append(entry)
                continue
            }
            let kept = hooks.filter { isFingerprintedHook($0, descriptor: descriptor) == false }
            guard kept.isEmpty == false else { continue }
            object["hooks"] = .array(kept)
            nextEntries.append(.object(object))
        }
        return nextEntries
    }

    static func insertEntries(
        into root: [String: JSONValue],
        descriptor: HostWiringDescriptor,
        context: HookCommandContext
    ) -> [String: JSONValue] {
        switch descriptor.layout {
        case .nested(let hooksRootKey, let listKey):
            var next = root
            var hooksRoot = next[hooksRootKey]?.asObject ?? [:]
            var list = hooksRoot[listKey]?.asArray ?? []
            for matcher in descriptor.matchers {
                list.append(.object([
                    "matcher": .string(matcher),
                    "hooks": .array([hookValue(descriptor.buildEntry(context, matcher))]),
                ]))
            }
            hooksRoot[listKey] = .array(list)
            next[hooksRootKey] = .object(hooksRoot)
            return next
        case .grouped(let hookName, let listKey):
            var next = root
            var group = next[hookName]?.asObject ?? [:]
            var list = group[listKey]?.asArray ?? []
            for matcher in descriptor.matchers {
                list.append(.object([
                    "matcher": .string(matcher),
                    "hooks": .array([hookValue(descriptor.buildEntry(context, matcher))]),
                ]))
            }
            group["enabled"] = .bool(true)
            group[listKey] = .array(list)
            next[hookName] = .object(group)
            return next
        case .flat(let hooksRootKey, let listKeys, let versionKey, let schemaVersion):
            var next = root
            var hooksRoot = next[hooksRootKey]?.asObject ?? [:]
            for key in listKeys {
                var list = hooksRoot[key]?.asArray ?? []
                list.append(hookValue(descriptor.buildEntry(context, nil)))
                hooksRoot[key] = .array(list)
            }
            next[hooksRootKey] = .object(hooksRoot)
            if let versionKey, let schemaVersion, next[versionKey] == nil {
                next[versionKey] = .number(Double(schemaVersion))
            }
            return next
        }
    }

    /// Serializes one typed entry to its historical JSON shape.
    static func hookValue(_ entry: HookEntry) -> JSONValue {
        var dict: [String: JSONValue] = [
            "command": .string(entry.command),
            "timeout": .number(Double(entry.timeout)),
        ]
        if let type = entry.type {
            dict["type"] = .string(type)
        }
        if let failClosed = entry.failClosed {
            dict["failClosed"] = .bool(failClosed)
        }
        if let statusMessage = entry.statusMessage {
            dict["statusMessage"] = .string(statusMessage)
        }
        return .object(dict)
    }

    /// `[String: Any]` bridge for the frozen `HostWiring` boundary: re-encode
    /// and re-parse so every read stays typed. Host roots always come from
    /// JSON bytes, so the round-trip is lossless; anything else yields nil.
    static func typedRoot(from object: [String: Any]) -> [String: JSONValue]? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let root = value.asObject
        else {
            return nil
        }
        return root
    }

    static func parseRoot(_ data: Data?) throws -> [String: JSONValue] {
        guard let data else { return [:] }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.asObject
        else {
            throw HostHooksMergeError.unreadable
        }
        return object
    }

    private static func encode(_ root: [String: JSONValue]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(JSONValue.object(root)) else {
            throw HostHooksMergeError.unreadable
        }
        return data
    }
}
