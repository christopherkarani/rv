import Foundation
import RVDomain

/// The glossary's Enabled packs: the pack IDs an Evaluate session request carries.
/// One resolution door for every caller in both processes.
public enum EnabledPacks {
    /// Resolves the enabled packs for an Evaluate session request.
    ///
    /// An unreadable config or registry falls back to the day-one packs;
    /// a readable config resolves exactly what it says, empty included.
    public static func resolve(home: String) -> [PackID] {
        (try? PacksFacade.effectiveIDs(home: home)) ?? dayOnePackIDs
    }

    /// The operator's HOME as this process sees it; empty when unset.
    static func processHome() -> String {
        ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? ""
    }
}
