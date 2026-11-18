import Foundation

/// Guard posture for the whole evaluate door — packs and judge alike.
public enum GuardMode: String, Sendable {
    /// Normal operation: packs deny, judge (when on) may raise an allow.
    case enforce
    /// Everything is evaluated and logged, nothing blocks. The would-be
    /// verdict (packs, script check, judge) lands in judge-log.jsonl.
    case observe
}

/// Which judge scores a pack-allowed command.
///
/// `ft` is the Ticket 5a single-pass fine-tune (bundle
/// `models/laya-ft-v2-coreml`); `laya` is the stock three-question CoreML
/// judge (bundle `models/laya-multilingual-coreml`).
public enum JudgeEngine: String, Sendable {
    case ft
    case laya
}

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

/// The owner-config keys that decide guard posture and judge engine
/// (`guard.mode`, `guard.hosts.<host>`, `judge.engine`), decoded once from
/// `config.json`. Pure: `GuardConfig.read` (RVPolicy) is the file shell.
public struct GuardConfig: Sendable, Equatable {
    /// `guard.mode`; nil when unset or unparseable.
    public var mode: GuardMode?
    /// `guard.hosts`, nested form only; unknown hosts and modes are skipped.
    public var hosts: [HookHost: HostMode]
    /// `judge.engine`; nil when unset or unparseable.
    public var judgeEngine: JudgeEngine?

    public static let empty = GuardConfig()

    public init(mode: GuardMode? = nil, hosts: [HookHost: HostMode] = [:], judgeEngine: JudgeEngine? = nil) {
        self.mode = mode
        self.hosts = hosts
        self.judgeEngine = judgeEngine
    }

    /// Decodes `config.json` bytes: the one bytes-to-config entry, shared
    /// by `GuardConfig.read` and the hook's daemon-down fallback. Text that
    /// `init(validatingJSON:)` rejects is `.empty`: parsers disagree on
    /// which duplicate wins, so a duplicate never selects observe.
    public init(jsonData: Data) {
        self = GuardConfig(validatingJSON: jsonData) ?? .empty
    }

    /// Decodes `config.json` bytes, or nil when the text does not parse, is
    /// not an object, or fails `JSONDuplicateKeys` (a repeated key in any
    /// object, too deep, not UTF-8). For callers that must tell a rejected
    /// file from one with no guard keys.
    public init?(validatingJSON jsonData: Data) {
        guard JSONDuplicateKeys.allObjectKeysDistinct(jsonData),
              let root = try? JSONDecoder().decode(JSONValue.self, from: jsonData),
              case .object = root
        else { return nil }
        self.init(root)
    }

    /// Decodes a parsed `config.json`. A non-object root is `.empty`.
    ///
    /// `mode` and `judgeEngine` take the nested string when non-empty, else
    /// the flat dotted one, then lowercase and parse it. An unparseable
    /// chosen value is nil; it never falls back to the other form.
    public init(_ root: JSONValue) {
        guard case .object = root else {
            self = .empty
            return
        }
        self.init(
            mode: Self.chosenRaw(root, object: "guard", key: "mode").flatMap { GuardMode(rawValue: $0.lowercased()) },
            hosts: Self.hostModes(root),
            judgeEngine: Self.chosenRaw(root, object: "judge", key: "engine").flatMap { JudgeEngine(rawValue: $0.lowercased()) }
        )
    }

    /// The machine-wide mode: no host entry, no environment.
    public var machineMode: GuardMode {
        GuardModeResolution.resolve(self, host: nil, environment: [:])
    }

    /// `root[object][key]` if a non-empty string, else `root["object.key"]`
    /// if a non-empty string.
    private static func chosenRaw(_ root: JSONValue, object: String, key: String) -> String? {
        if let nested = root[object]?[key]?.string, !nested.isEmpty {
            return nested
        }
        if let flat = root["\(object).\(key)"]?.string, !flat.isEmpty {
            return flat
        }
        return nil
    }

    private static func hostModes(_ root: JSONValue) -> [HookHost: HostMode] {
        guard let entries = root["guard"]?["hosts"]?.asObject else { return [:] }
        var modes: [HookHost: HostMode] = [:]
        for (key, value) in entries {
            guard let host = HookHost(rawValue: key),
                  let raw = value.string,
                  let mode = HostMode(rawValue: raw.lowercased())
            else { continue }
            modes[host] = mode
        }
        return modes
    }
}

/// The guard-mode ladder: `RV_GUARD_MODE=enforce` > `guard.hosts.<host>` >
/// `guard.mode` > enforce. Callers apply the organization pin
/// (`ManagedGate.guardMode`) afterwards.
public enum GuardModeResolution {
    /// The environment can only tighten: only `enforce` (any case) is
    /// honoured, because rvd's launch environment is same-user editable. A
    /// host entry of `block` is enforce; `observe` and `off` are observe (an
    /// `off` host should be unwired, so a stale hook that still fires must
    /// never block).
    public static func resolve(_ config: GuardConfig, host: HookHost?, environment: [String: String]) -> GuardMode {
        if let raw = environment["RV_GUARD_MODE"],
           GuardMode(rawValue: raw.lowercased()) == .enforce {
            return .enforce
        }
        if let host, let hostMode = config.hosts[host] {
            return hostMode == .block ? .enforce : .observe
        }
        return config.mode ?? .enforce
    }
}
