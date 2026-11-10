import Foundation
import RVDomain
import RVEngine
import RVPacks
import RVPolicy

/// Pack IDs this evaluate walks. Config as written. Empty included. May omit day-one.
public struct WalkedPackIDs: Sendable, Equatable {
    public let ids: [PackID]

    public init(ids: [PackID]) {
        self.ids = ids
    }
}

/// Pack IDs compiled into an Evaluate session. Coverage always unions day-one;
/// an explicit list (tests, empty wire) may omit them.
public struct CompiledPackIDs: Sendable, Equatable {
    public let ids: [PackID]

    /// Raw compile list. Does not union day-one; use `PackCoverage.unioningDayOne`
    /// when the IDs came from a walk set.
    package init(ids: [PackID]) {
        self.ids = ids
    }
}

/// Walk set plus the compile set derived from it. Compile = walk ∪ day-one.
public struct PackCoverage: Sendable, Equatable {
    public let walked: WalkedPackIDs
    public let compiled: CompiledPackIDs

    private init(walked: WalkedPackIDs, compiled: CompiledPackIDs) {
        self.walked = walked
        self.compiled = compiled
    }

    /// Walked order preserved; missing day-one IDs appended. The only walk→compile union.
    public static func unioningDayOne(_ walked: WalkedPackIDs) -> PackCoverage {
        var compiled = walked.ids
        for id in dayOnePackIDs where !compiled.contains(id) {
            compiled.append(id)
        }
        return PackCoverage(walked: walked, compiled: CompiledPackIDs(ids: compiled))
    }
}

/// The one assembly site for an evaluation world: snapshot fallback chain,
/// enabled-ID rule, and the door around the resulting session.
package enum EvaluationWorld {
    /// Walk set from config. Nil or unreadable HOME is day-one. Empty config is empty.
    /// Packs the signed organization policy requires (`gate.requirePacks`)
    /// are always added: user config can never drop them.
    package static func walkedPackIDs(home: HomeDirectory?) -> WalkedPackIDs {
        var ids: [PackID]
        if let home {
            ids = (try? PacksFacade.effectiveIDs(home: home)) ?? dayOnePackIDs
        } else {
            ids = dayOnePackIDs
        }
        for id in ManagedGate.requiredPacks(home: home) where ids.contains(id) == false {
            ids.append(id)
        }
        return WalkedPackIDs(ids: ids)
    }

    /// Full catalog first; day-one when the index is missing; none when both fail.
    package static func resolveSnapshots(_ provided: [PackSnapshot]?) -> [PackSnapshot] {
        provided ?? ((try? PackRegistry.loadAll()) ?? ((try? PackRegistry.loadDayOne()) ?? []))
    }

    /// Walk from catalog flags or config; compile = walk ∪ day-one.
    /// Nil home is day-one walk, not process HOME.
    package static func coverage(
        catalog: PackCatalog?,
        home: HomeDirectory?
    ) -> PackCoverage {
        let walked: WalkedPackIDs
        if let catalog {
            var ids = catalog.records.isEmpty
                ? dayOnePackIDs
                : catalog.records.filter(\.isEnabled).map(\.id)
            // Org-required packs are compiled whatever the catalog flags say;
            // otherwise the walk wants a pack the session never compiled and
            // the engine skips it.
            for id in ManagedGate.requiredPacks(home: home) where ids.contains(id) == false {
                ids.append(id)
            }
            walked = WalkedPackIDs(ids: ids)
        } else {
            walked = walkedPackIDs(home: home)
        }
        return PackCoverage.unioningDayOne(walked)
    }

    /// Eager session for callers that need readiness at build time (rvd).
    package static func makeSession(
        coverage: PackCoverage,
        snapshots: [PackSnapshot]?
    ) -> EvaluateSession {
        EvaluateSession(
            snapshots: resolveSnapshots(snapshots),
            compiledPacks: coverage.compiled
        )
    }

    /// The assembly door; its session builds on first use, never here.
    package static func assemble(
        home: HomeDirectory?,
        snapshots: [PackSnapshot]?,
        catalog: PackCatalog?
    ) -> GatedEvaluate {
        GatedEvaluate(lazySession: {
            makeSession(
                coverage: coverage(catalog: catalog, home: home),
                snapshots: snapshots
            )
        })
    }

    /// T1 matching view for grant mint, allowlist, exact-command rule pin, and explain render.
    package static func matchingView(of command: ShellCommand) -> MatchingView {
        Normalize.matchingView(of: command)
    }
}
