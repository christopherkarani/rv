import Foundation
import RVDomain

/// How rv guards one hook host. `block` enforces, `observe` allows and logs
/// what enforcement would have blocked, `off` leaves the host unwired. A
/// host with no stored entry is `block`.
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
    /// `config.json` exists but is not a JSON object: writing would drop
    /// every other key, so nothing is written.
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

    /// Stored entries only; a host missing here is `block`.
    public func load() -> [HookHost: HostMode] {
        guard let data = try? Data(contentsOf: configFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return Self.modes(inConfig: root)
    }

    public func mode(for host: HookHost) -> HostMode {
        load()[host] ?? .block
    }

    /// Writes one host's entry; `block` removes it. Every other key is kept.
    public func save(_ mode: HostMode, for host: HookHost) throws {
        if let data = try? Data(contentsOf: configFile),
           (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) == nil {
            throw HostModeStoreError.unreadableConfig
        }
        try MachineConfigJSON.update(file: configFile) { root in
            var guardObject = root["guard"]?.asObject ?? [:]
            var hosts = guardObject["hosts"]?.asObject ?? [:]
            if mode == .block {
                hosts[host.rawValue] = nil
            } else {
                hosts[host.rawValue] = .string(mode.rawValue)
            }
            guardObject["hosts"] = hosts.isEmpty ? nil : .object(hosts)
            root["guard"] = guardObject.isEmpty ? nil : .object(guardObject)
        }
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
