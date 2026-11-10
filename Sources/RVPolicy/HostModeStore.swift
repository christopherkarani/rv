import Foundation
import RVDomain

/// How rv guards one hook host. `block` enforces, `observe` allows and logs
/// what enforcement would have blocked, `off` leaves the host unwired. A
/// host with no stored entry follows the global `guard.mode` (enforce by
/// default); a stored entry, `block` included, outranks it.
public enum HostMode: String, Sendable, Equatable, CaseIterable {
    case block
    case observe
    case off

    /// True when moving from `current` to `self` sheds oversight.
    public func isLooser(than current: HostMode) -> Bool {
        rank < current.rank
    }

    private var rank: Int {
        switch self {
        case .off: 0
        case .observe: 1
        case .block: 2
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

    /// Stored entries only; a host missing here follows `guard.mode`.
    public func load() -> [HookHost: HostMode] {
        guard let data = try? Data(contentsOf: configFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return Self.modes(inConfig: root)
    }

    /// The stored entry, or `block` when there is none. Callers that ask
    /// "is this a loosening?" use it: treating a missing entry as `block`
    /// means pinning `observe` over a global observe still needs the owner.
    public func mode(for host: HookHost) -> HostMode {
        load()[host] ?? .block
    }

    /// Writes one host's entry, `block` included: an explicit `block` must
    /// outrank a global `guard.mode: observe`. Every other key is kept. The
    /// read, the checks and the write share one lock; a config that is not
    /// an object, or a non-object `guard` / `guard.hosts`, throws
    /// `unreadableConfig` and nothing is written.
    public func save(_ mode: HostMode, for host: HookHost) throws {
        do {
            try MachineConfigJSON.updateExistingObject(file: configFile) { root in
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
        do {
            try MachineConfigJSON.updateExistingObject(file: configFile) { root in
                var guardObject = try Self.object(root["guard"])
                guardObject["mode"] = .string("observe")
                root["guard"] = .object(guardObject)
            }
        } catch MachineConfigJSONError.notAnObject {
            throw HostModeStoreError.unreadableConfig
        }
    }

    private static func object(_ value: JSONValue?) throws(HostModeStoreError) -> [String: JSONValue] {
        guard let value else { return [:] }
        guard let object = value.asObject else { throw .unreadableConfig }
        return object
    }

    /// Reads `guard.hosts` from an already-parsed config object (rvd parses
    /// `config.json` once per evaluation).
    public static func modes(inConfig config: [String: Any]?) -> [HookHost: HostMode] {
        guard let guardObject = config?["guard"] as? [String: Any],
              let hosts = guardObject["hosts"] as? [String: Any]
        else { return [:] }
        var modes: [HookHost: HostMode] = [:]
        for (key, value) in hosts {
            guard let host = HookHost(rawValue: key),
                  let raw = value as? String,
                  let mode = HostMode(rawValue: raw.lowercased())
            else { continue }
            modes[host] = mode
        }
        return modes
    }
}
