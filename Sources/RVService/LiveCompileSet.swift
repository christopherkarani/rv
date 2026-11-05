import Foundation
import RVDomain
import RVPacks
import RVPolicy

/// The live compile-set module: one owner for the daemon's catalog,
/// snapshots, compiled `GatedEvaluate` door, and the freshness rule that
/// keeps that door covering what callers ask to evaluate.
///
/// Interface: callers request a ready door/world for a wanted walk set
/// (`readyDoor` / `readyWorld` / `livePeek`) and evaluate against what
/// comes back; nobody outside this module rebuilds, reloads the catalog,
/// or checks coverage by hand. `setPackEnabled` is the single pack
/// mutation entry. The depth is in the rule this hides:
///
/// - A wanted set the compiled set already covers returns the current
///   door untouched (no catalog reload, no rebuild).
/// - An uncovered wanted set reloads the catalog from disk and rebuilds
///   before the door is handed out, so a behind-our-back config edit
///   (`rv packs enable` writes config directly) is healed before the
///   evaluate that names the pack. Uncompiled-but-requested packs would
///   otherwise be dropped toward allow.
/// - A rebuild that still leaves the same wanted set uncovered (a pack
///   that can never compile) is retried at most once per second for that
///   identical wanted set, so it costs one rebuild per interval, not one
///   per evaluate.
/// - `setPackEnabled` rebuilds immediately and clears the throttle slot,
///   so the first door requested after it — even inside the throttle
///   window — already covers the change.
///
/// State sits behind one lock internal to this module: the hook ceremony
/// is built in `ServiceRuntime.init` before `self` can be captured, so
/// callers share this reference and read the same live set at peek time.
/// Rebuild work (catalog read, session compile) runs under that lock, so
/// a concurrent covered read also waits out an in-flight rebuild; the
/// compile is bounded, and publishing only under the lock is what keeps
/// a slower heal from overwriting a fresher door.
package final class LiveCompileSet: Sendable {
    /// Readiness of the door compiled at init. Fixed for the daemon's
    /// lifetime handshake, exactly as the runtime has always reported it;
    /// later rebuilds do not rewrite it.
    package let corePacksReady: Bool

    private struct State {
        var catalog: PackCatalog
        var door: GatedEvaluate
        var compiledPackIDs: [PackID]
        var compiledIDSet: Set<PackID>
        var lastUncoveredWanted: Set<PackID> = []
        var lastCoverageRebuildAt: UInt64 = 0
    }

    private let state: UnfairLock<State>
    private let snapshots: [PackSnapshot]
    private let home: HomeDirectory?
    private let uptimeNanoseconds: @Sendable () -> UInt64

    package init(
        snapshots providedSnapshots: [PackSnapshot]?,
        catalog providedCatalog: PackCatalog?,
        home: HomeDirectory?,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        let catalog = providedCatalog ?? Self.makeCatalog(home: home) ?? PackCatalog()
        let snapshots = EvaluationWorld.resolveSnapshots(providedSnapshots)
        let session = EvaluateSession(
            snapshots: snapshots,
            compiledPacks: EvaluationWorld.coverage(catalog: catalog, home: home).compiled
        )
        self.snapshots = snapshots
        self.home = home
        self.uptimeNanoseconds = uptimeNanoseconds
        self.corePacksReady = session.corePacksReady
        self.state = UnfairLock(State(
            catalog: catalog,
            door: GatedEvaluate(session),
            compiledPackIDs: session.compiledPackIDs,
            compiledIDSet: Set(session.compiledPackIDs)
        ))
    }

    /// Sorted pack IDs in the current compiled set.
    package var compiledPackIDs: [PackID] {
        state.withLock { $0.compiledPackIDs }
    }

    /// The catalog the current compiled set was built from (or the last
    /// disk refresh). Read for list/doctor records.
    package var catalog: PackCatalog {
        state.withLock { $0.catalog }
    }

    package var analyticsEnabledPackIDs: [String] {
        state.withLock { $0.catalog.enabledIDs.map(\.rawValue) }
    }

    /// The ready door covering `wanted`, rebuilt first when the compiled
    /// set does not cover it (throttle rule in the module doc).
    package func readyDoor(wanted: WalkedPackIDs) -> GatedEvaluate {
        state.withLock { state in
            healWhenUncovered(wantedIDs: wanted.ids, state: &state)
            return state.door
        }
    }

    /// A live world over the ready door covering `wanted`. The door is
    /// resolved here, at world-build time, so the world cannot evaluate
    /// against a stale snapshot.
    package func readyWorld(
        wanted: WalkedPackIDs,
        store: AllowOnceStore,
        grants: EphemeralAllowOnceTable,
        clock: @escaping @Sendable () -> Date
    ) -> LiveEvaluateWorld {
        LiveEvaluateWorld(
            home: home,
            store: store,
            grants: grants,
            gated: readyDoor(wanted: wanted),
            clock: clock
        )
    }

    /// Frozen-clock allow-once peek with freshness resolved per call:
    /// the wanted set is the config walk for this module's home — the
    /// same walk the peeked request carries — and the door is healed to
    /// cover it before the peek runs. `store` nil keeps the world's
    /// default store for that home (allowlist directory only; grants
    /// are authority).
    package func livePeek(
        store: AllowOnceStore?,
        grants: EphemeralAllowOnceTable
    ) -> @Sendable (ShellCommand, WorkingDirectory?, Date) async -> EvaluationResult {
        { command, cwd, now in
            await LiveEvaluateWorld(
                home: self.home,
                store: store,
                grants: grants,
                gated: self.readyDoor(wanted: EvaluationWorld.walkedPackIDs(home: self.home)),
                clock: { now }
            ).peek(command: command, cwd: cwd)
        }
    }

    /// The single pack-enablement mutation entry: writes config through
    /// the facade, reloads the catalog, rebuilds at once, and clears the
    /// throttle slot. A module with no home throws
    /// `LiveCompileSetError.missingHome` before touching the facade;
    /// facade failures throw `PacksCommandError`.
    package func setPackEnabled(_ id: PackID, enabled: Bool) throws {
        guard let home else { throw LiveCompileSetError.missingHome }
        try state.withLock { state in
            if enabled {
                _ = try PacksFacade.enable(home: home, ids: [id.rawValue])
            } else {
                _ = try PacksFacade.disable(home: home, ids: [id.rawValue])
            }
            state.catalog = try PacksFacade.makeCatalog(home: home)
            rebuild(state: &state)
            state.lastUncoveredWanted = []
        }
    }

    /// Config is the operator switch: reload the catalog from disk and
    /// heal coverage so a local `rv packs enable` is visible to
    /// list/doctor without bouncing the daemon. Returns the catalog.
    @discardableResult
    package func refreshCatalogFromDisk() -> PackCatalog {
        state.withLock { state in
            if let refreshed = Self.makeCatalog(home: home) {
                state.catalog = refreshed
            }
            healWhenUncovered(
                wantedIDs: EvaluationWorld.coverage(catalog: state.catalog, home: home)
                    .compiled.ids,
                state: &state
            )
            return state.catalog
        }
    }

    // MARK: - Freshness rule (runs under the state lock)

    private func healWhenUncovered(wantedIDs: [PackID], state: inout State) {
        guard wantedIDs.contains(where: { !state.compiledIDSet.contains($0) }) else { return }
        let wanted = Set(wantedIDs)
        let now = uptimeNanoseconds()
        if wanted == state.lastUncoveredWanted,
           now < state.lastCoverageRebuildAt &+ 1_000_000_000
        {
            return
        }
        state.lastUncoveredWanted = wanted
        state.lastCoverageRebuildAt = now
        state.catalog = Self.makeCatalog(home: home) ?? state.catalog
        rebuild(state: &state)
    }

    private func rebuild(state: inout State) {
        let session = EvaluateSession(
            snapshots: snapshots,
            compiledPacks: EvaluationWorld.coverage(catalog: state.catalog, home: home).compiled
        )
        state.compiledPackIDs = session.compiledPackIDs
        state.compiledIDSet = Set(session.compiledPackIDs)
        state.door = GatedEvaluate(session)
    }

    /// Catalog for a home; nil home mirrors the old empty-HOME catalog
    /// with the day-one packs enabled.
    private static func makeCatalog(home: HomeDirectory?) -> PackCatalog? {
        guard let home else {
            return try? PackCatalog.make(
                enabled: Set(dayOnePackIDs),
                index: PackRegistry.loadIndex()
            )
        }
        return try? PacksFacade.makeCatalog(home: home)
    }
}

package enum LiveCompileSetError: Error, Sendable, Equatable {
    case missingHome
}
