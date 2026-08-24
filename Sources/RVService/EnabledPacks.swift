import RVDomain
import RVPolicy

/// The glossary's Enabled packs: the pack IDs an Evaluate session request carries.
/// One resolution door for every caller in both processes.
public enum EnabledPacks {
    /// Resolves the enabled packs for an Evaluate session request.
    ///
    /// A nil home falls back to the day-one packs; an unreadable config or
    /// registry falls back to the day-one packs; a readable config resolves
    /// exactly what it says, empty included.
    public static func resolve(home: HomeDirectory?) -> WalkedPackIDs {
        guard let home else { return WalkedPackIDs(ids: dayOnePackIDs) }
        return WalkedPackIDs(ids: (try? PacksFacade.effectiveIDs(home: home)) ?? dayOnePackIDs)
    }
}
