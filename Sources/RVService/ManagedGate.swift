import Foundation
import RVDomain
import RVIsolation
import RVPolicy
import Synchronization

/// Organization gate requirements (`gate` in the signed managed policy),
/// read by every evaluation door.
///
/// The installed bundle is verified (ownership chain, Ed25519 signature,
/// anti-rollback serial) on load. Hooks run on every tool call, so the
/// verified state is cached briefly; a policy change applies within
/// `cacheLifetime`.
public enum ManagedGate {
    /// The safety level evaluation actually uses: the user's and repo's
    /// setting, raised to strict by the organization gate. For display
    /// (`rv safety`, `rv doctor`), so they match what hooks enforce.
    public static func effectiveSafety(home: HomeDirectory?, workspace: URL?) -> SafetyLevel {
        safety(SafetyStore.loadEffective(home: home, workspace: workspace), home: home)
    }

    static let cacheLifetime: TimeInterval = 5

    /// Tests set this to evaluate under a given managed state without a
    /// root-owned bundle on disk.
    @TaskLocal static var override: ManagedPolicyState?

    private struct Cached {
        var state: ManagedPolicyState
        /// `gate.requirePacks` of the installed bundle when it is signed and
        /// root-owned but `state` is invalid (for example the user-owned
        /// anti-rollback serial file is corrupt or locked).
        var signedPacks: [PackID]
        var configDirectory: String
        var loadedAt: Date
    }

    private static let cache = Mutex<Cached?>(nil)

    static func state(home: HomeDirectory?, now: Date = Date()) -> ManagedPolicyState {
        loaded(home: home, now: now).state
    }

    private static func loaded(home: HomeDirectory?, now: Date = Date()) -> (state: ManagedPolicyState, signedPacks: [PackID]) {
        if let override { return (override, override.policy?.gate.requirePacks ?? []) }
        let configDirectory = home.map { RVPolicyPaths.configDirectory(home: $0) }
        let key = configDirectory?.path ?? ""
        if let cached = cache.withLock({ $0 }),
           cached.configDirectory == key,
           now.timeIntervalSince(cached.loadedAt) < cacheLifetime,
           now >= cached.loadedAt {
            return (cached.state, cached.signedPacks)
        }
        let state = configDirectory.map { ManagedPolicyLocation.installed.load(serialsIn: $0) }
            ?? ManagedPolicyLocation.installed.load()
        let signedPacks: [PackID]
        switch state {
        case .active(let bundle):
            signedPacks = bundle.policy.gate.requirePacks
        case .none:
            signedPacks = []
        case .invalid:
            // The serial check reads a user-owned file, so a same-user
            // process can make it fail. That must not drop the packs a
            // signed, root-owned bundle requires.
            signedPacks = ManagedPolicyLocation.installed.load().policy?.gate.requirePacks ?? []
        }
        cache.withLock {
            $0 = Cached(state: state, signedPacks: signedPacks, configDirectory: key, loadedAt: now)
        }
        return (state, signedPacks)
    }

    /// Packs the organization requires on every door. An invalid bundle
    /// still contributes the packs its signed policy names when only the
    /// user-owned serial check failed; it also forces strict safety (see
    /// `safety`).
    static func requiredPacks(home: HomeDirectory?) -> [PackID] {
        loaded(home: home).signedPacks
    }

    /// `mode` forced to `.enforce` while an organization gate applies (or a
    /// managed bundle is present but untrustworthy): observe mode, which a
    /// same-user process can turn on through the environment or
    /// `config.json`, would otherwise switch every gate requirement off.
    static func guardMode(_ mode: GuardMode, home: HomeDirectory?) -> GuardMode {
        switch state(home: home) {
        case .none:
            return mode
        case .invalid:
            return .enforce
        case .active(let bundle):
            let gate = bundle.policy.gate
            return gate.requireStrictSafety || gate.requirePacks.isEmpty == false ? .enforce : mode
        }
    }

    /// True while the organization pins enforce: observe mode, global or
    /// per host, has no effect on evaluation then (`rv host list`).
    public static func pinsEnforce(home: HomeDirectory?) -> Bool {
        guardMode(.observe, home: home) == .enforce
    }

    /// `level` raised to strict when the organization requires it, or when
    /// a managed bundle is present but cannot be trusted (fail closed).
    static func safety(_ level: SafetyLevel, home: HomeDirectory?) -> SafetyLevel {
        switch state(home: home) {
        case .none:
            return level
        case .invalid:
            return .strict
        case .active(let bundle):
            return bundle.policy.gate.requireStrictSafety ? .strict : level
        }
    }
}
