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
enum ManagedGate {
    static let cacheLifetime: TimeInterval = 5

    /// Tests set this to evaluate under a given managed state without a
    /// root-owned bundle on disk.
    @TaskLocal static var override: ManagedPolicyState?

    private struct Cached {
        var state: ManagedPolicyState
        var configDirectory: String
        var loadedAt: Date
    }

    private static let cache = Mutex<Cached?>(nil)

    static func state(home: HomeDirectory?, now: Date = Date()) -> ManagedPolicyState {
        if let override { return override }
        guard let home else { return ManagedPolicyLocation.installed.load() }
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        if let cached = cache.withLock({ $0 }),
           cached.configDirectory == configDirectory.path,
           now.timeIntervalSince(cached.loadedAt) < cacheLifetime,
           now >= cached.loadedAt {
            return cached.state
        }
        let state = ManagedPolicyLocation.installed.load(serialsIn: configDirectory)
        cache.withLock { $0 = Cached(state: state, configDirectory: configDirectory.path, loadedAt: now) }
        return state
    }

    /// Packs the organization requires on every door. An invalid bundle
    /// adds none here; it forces strict safety instead (see `safety`).
    static func requiredPacks(home: HomeDirectory?) -> [PackID] {
        state(home: home).policy?.gate.requirePacks ?? []
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
