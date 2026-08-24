import RVDomain
import RVPolicy

/// The glossary's Enabled packs: the pack IDs an Evaluate session request carries.
/// One resolution door for every caller in both processes.
public enum EnabledPacks {
    /// Resolves the walk set for an Evaluate session request.
    ///
    /// A nil home is day-one; an unreadable config or registry falls back to
    /// day-one; a readable config resolves exactly what it says, empty included.
    package static func resolve(home: HomeDirectory?) -> WalkSet {
        guard let home else { return WalkSet(ids: dayOnePackIDs) }
        return WalkSet(ids: (try? PacksFacade.effectiveIDs(home: home)) ?? dayOnePackIDs)
    }
}
