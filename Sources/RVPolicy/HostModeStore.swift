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
    /// outrank a global `guard.mode: observe`. Every other key is kept.
    /// Written through `MachineConfigJSON.set`: a config that is not an
    /// object, text `JSONDuplicateKeys` rejects, or a non-object `guard` /
    /// `guard.hosts` throws `OwnerConfigWriteError.unreadable` and nothing
    /// is written. Records `config.changed` (`guard.hosts.<host>`)
    /// write-ahead when the stored entry changes. `beforeWrite` runs after
    /// that record and before the file moves (`rv host mode <host> off`
    /// detaches the hooks there, so an unrecorded `off` never unwires a host).
    public func save(_ mode: HostMode, for host: HookHost, beforeWrite: () throws -> Void = {}) throws {
        let setting = MachineConfigJSON.Setting(
            keyPath: ["guard", "hosts", host.rawValue], describe: Self.describe,
            direction: { prior, _ in Self.direction(from: Self.describe(prior), to: mode) })
        try MachineConfigJSON.set(.string(mode.rawValue), for: setting, in: configFile, beforeWrite: beforeWrite)
    }

    /// The whole decoded guard config, or nil when the file exists but
    /// cannot be read or `GuardConfig` rejects it (as `read` is `.unreadable`).
    public func readGuardConfig() -> GuardConfig? {
        let data: Data
        do {
            data = try Data(contentsOf: configFile)
        } catch CocoaError.fileReadNoSuchFile {
            return .empty
        } catch {
            return nil
        }
        return GuardConfig(validatingJSON: data)
    }

    /// Stores an agent's block of `host` that holds only for `window`
    /// (`guard.temporary_blocks.<host>`). `guard.hosts.<host>` is left as it
    /// is: when the window closes, that stored mode is back with nothing to
    /// restore. Recorded as a tightening, with the same refusals as `save`.
    public func saveTemporaryBlock(for host: HookHost, window: GuardWindow) throws {
        let setting = MachineConfigJSON.Setting(
            keyPath: Self.temporaryBlockKeyPath(host), describe: Self.describeTemporaryBlock,
            direction: { _, _ in .tightening })
        try MachineConfigJSON.set(window.json, for: setting, in: configFile)
    }

    /// Ends `host`'s open temporary block at `now` (the owner loosening it
    /// early). The record stays, ended, so the cooldown counts from `now`.
    /// Recorded as a loosening.
    public func endTemporaryBlock(for host: HookHost, window: GuardWindow, at now: Date) throws {
        let setting = MachineConfigJSON.Setting(
            keyPath: Self.temporaryBlockKeyPath(host), describe: Self.describeTemporaryBlock,
            direction: { _, _ in .loosening })
        try MachineConfigJSON.set(window.ended(at: now).json, for: setting, in: configFile)
    }

    /// Removes `host`'s temporary block. `direction` is how the removal
    /// reads in the audit trail: a loosening when the owner ends an open
    /// block, a tightening when a permanent `block` replaces it.
    public func clearTemporaryBlock(for host: HookHost, direction: ConfigChangeAudit.Direction) throws {
        let setting = MachineConfigJSON.Setting(
            keyPath: Self.temporaryBlockKeyPath(host), describe: Self.describeTemporaryBlock,
            direction: { _, _ in direction })
        try MachineConfigJSON.set(nil, for: setting, in: configFile)
    }

    /// Stores the owner's pause (`guard.pause`): every host observes while
    /// `window` is open. Recorded as a loosening; the caller binds the
    /// owner check to `ConfigChangeAudit.authorization` first.
    public func savePause(_ window: GuardWindow) throws {
        let setting = MachineConfigJSON.Setting(
            keyPath: Self.pauseKeyPath, describe: Self.describePause, direction: { _, _ in .loosening })
        try MachineConfigJSON.set(window.json, for: setting, in: configFile)
    }

    /// Ends the pause now (`rv pause --end`): a tightening, needing no owner.
    public func clearPause() throws {
        let setting = MachineConfigJSON.Setting(
            keyPath: Self.pauseKeyPath, describe: Self.describePause, direction: { _, _ in .tightening })
        try MachineConfigJSON.set(nil, for: setting, in: configFile)
    }

    private static func temporaryBlockKeyPath(_ host: HookHost) -> [String] {
        ["guard", "temporary_blocks", host.rawValue]
    }

    private static let pauseKeyPath = ["guard", "pause"]

    private static func describeTemporaryBlock(_ value: JSONValue?) -> String {
        guard let window = GuardWindow(json: value) else { return ConfigChangeAudit.unset }
        return "block until \(Self.stamp(window.until))"
    }

    private static func describePause(_ value: JSONValue?) -> String {
        guard let window = GuardWindow(json: value) else { return ConfigChangeAudit.unset }
        return "paused until \(Self.stamp(window.until))"
    }

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Writes the machine-wide `guard.mode: observe` (`rv setup --observe`).
    /// Stored `guard.hosts` entries, and every other key, are kept; the
    /// same refusal as `save` applies.
    public func saveGlobalObserve() throws {
        let setting = MachineConfigJSON.Setting(
            keyPath: ["guard", "mode"], describe: Self.describe, direction: { _, _ in .loosening })
        try MachineConfigJSON.set(.string("observe"), for: setting, in: configFile)
    }

    /// A stored mode as the audit trail reads it: its string, else `unset`.
    private static func describe(_ value: JSONValue?) -> String {
        value?.string ?? ConfigChangeAudit.unset
    }

    /// `block` is the tightest mode; otherwise only a move away from a
    /// stored mode that `isLooser` than the new one tightens. A missing or
    /// unknown entry follows `guard.mode`, which can be anything.
    static func direction(from prior: String, to mode: HostMode) -> ConfigChangeAudit.Direction {
        if mode == .block { return .tightening }
        return HostMode(rawValue: prior)?.isLooser(than: mode) == true ? .tightening : .loosening
    }
}
