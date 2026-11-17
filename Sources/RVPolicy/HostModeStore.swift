import Foundation
import RVDomain
import RVHistory

/// What `config.json` stores under `guard.hosts` (`HostModeStore.read`).
public enum StoredHostModes: Sendable, Equatable {
    /// The file is missing, or `GuardConfig` accepts it.
    case entries([HookHost: HostMode])
    /// The file exists but could not be read, or `GuardConfig` rejects it.
    case unreadable

    /// The stored mode for `host`: its entry, else `block` (a host with no
    /// entry follows `guard.mode`; reading it as `block` means pinning
    /// `observe` over a global observe still needs the owner), else
    /// `ifUnreadable` when the file is unreadable.
    public func mode(for host: HookHost, ifUnreadable: HostMode) -> HostMode {
        switch self {
        case .entries(let entries): entries[host] ?? .block
        case .unreadable: ifUnreadable
        }
    }
}

public enum HostModeStoreError: Error, Sendable, Equatable {
    /// `config.json` exists but is not a JSON object, or its `guard` /
    /// `guard.hosts` value is not one: writing would drop or replace keys
    /// rv cannot read, so nothing is written.
    case unreadableConfig
}

/// `guard.hosts` in `~/.config/rv/config.json`:
/// `{"guard": {"hosts": {"claude": "observe", "cursor": "off"}}}`.
/// Unknown host keys and unknown values read as no entry.
public struct HostModeStore: Sendable {
    public var configDirectory: URL

    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
    }

    public var configFile: URL {
        configDirectory.appendingPathComponent("config.json", isDirectory: false)
    }

    /// The stored `guard.hosts` entries. A missing file has none. A file
    /// that exists but cannot be read, or that `GuardConfig` rejects (not
    /// JSON, not an object, a repeated key, too deep, not UTF-8), is
    /// `.unreadable`, never "no entries": rvd reads such a file as
    /// enforce, and each caller picks the conservative reading for its own
    /// question.
    public func read() -> StoredHostModes {
        let data: Data
        do {
            data = try Data(contentsOf: configFile)
        } catch CocoaError.fileReadNoSuchFile {
            return .entries([:])
        } catch {
            return .unreadable
        }
        guard let config = GuardConfig(validatingJSON: data) else { return .unreadable }
        return .entries(config.hosts)
    }

    /// Writes one host's entry, `block` included: an explicit `block` must
    /// outrank a global `guard.mode: observe`. Every other key is kept. The
    /// read, the checks and the write share one lock; a config that is not
    /// an object, or a non-object `guard` / `guard.hosts`, throws
    /// `unreadableConfig` and nothing is written.
    /// Records `config.changed` (`guard.hosts.<host>`) write-ahead when the
    /// stored entry changes. `beforeWrite` runs after that record and before
    /// the file moves (`rv host mode <host> off` detaches the hooks there,
    /// so an unrecorded `off` never unwires a host).
    public func save(_ mode: HostMode, for host: HookHost, beforeWrite: () throws -> Void = {}) throws {
        let audit: MachineConfigJSON.ChangeEvent = { before, _ in
            let prior = before["guard"]?["hosts"]?[host.rawValue]?.string ?? ConfigChangeAudit.unset
            guard prior != mode.rawValue else { return nil }
            return ConfigChangeAudit.setting(
                "guard.hosts.\(host.rawValue)", from: prior, to: mode.rawValue,
                direction: Self.direction(from: prior, to: mode))
        }
        do {
            try MachineConfigJSON.updateExistingObject(file: configFile, audit: audit, beforeWrite: beforeWrite) { root in
                var guardObject = try Self.object(root["guard"])
                var hosts = try Self.object(guardObject["hosts"])
                hosts[host.rawValue] = .string(mode.rawValue)
                guardObject["hosts"] = .object(hosts)
                root["guard"] = .object(guardObject)
            }
        } catch MachineConfigJSONError.notAnObject {
            throw HostModeStoreError.unreadableConfig
        }
    }

    /// Writes the machine-wide `guard.mode: observe` (`rv setup --observe`).
    /// Stored `guard.hosts` entries, and every other key, are kept; the
    /// same `unreadableConfig` rule as `save` applies.
    public func saveGlobalObserve() throws {
        let audit: MachineConfigJSON.ChangeEvent = { before, _ in
            let prior = before["guard"]?["mode"]?.string ?? ConfigChangeAudit.unset
            guard prior != "observe" else { return nil }
            return ConfigChangeAudit.setting("guard.mode", from: prior, to: "observe", direction: .loosening)
        }
        do {
            try MachineConfigJSON.updateExistingObject(file: configFile, audit: audit) { root in
                var guardObject = try Self.object(root["guard"])
                guardObject["mode"] = .string("observe")
                root["guard"] = .object(guardObject)
            }
        } catch MachineConfigJSONError.notAnObject {
            throw HostModeStoreError.unreadableConfig
        }
    }

    /// `block` is the tightest mode; otherwise only a move away from a
    /// stored mode that `isLooser` than the new one tightens. A missing or
    /// unknown entry follows `guard.mode`, which can be anything.
    static func direction(from prior: String, to mode: HostMode) -> ConfigChangeAudit.Direction {
        if mode == .block { return .tightening }
        return HostMode(rawValue: prior)?.isLooser(than: mode) == true ? .tightening : .loosening
    }

    private static func object(_ value: JSONValue?) throws(HostModeStoreError) -> [String: JSONValue] {
        guard let value else { return [:] }
        guard let object = value.asObject else { throw .unreadableConfig }
        return object
    }
}
