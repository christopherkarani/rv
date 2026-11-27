import Foundation
import RVDomain
import RVEngine
import RVPacks

/// A pack that is off and would stop a command if it were on.
public struct OffPackHit: Equatable, Sendable {
    public var packID: PackID
    /// The pack's rule that would stop it (`database.redis:flushall`).
    public var ruleID: RuleID

    public init(packID: PackID, ruleID: RuleID) {
        self.packID = packID
        self.ruleID = ruleID
    }
}

/// Evaluates commands against bundled packs that are not the ones in force,
/// for `rv explain` ("would stop if database.redis were on").
///
/// Read-only and advisory: it runs the pinned pack `evaluate` on a pack set
/// of the caller's choosing and never changes a verdict. Patterns compile
/// on demand, and only for packs a command could reach (one of their
/// keywords is in its matching view: the engine skips a pack otherwise).
public struct PackProbe: Sendable {
    private let documents: [PackDocument]
    private let engine = ICUPatternEngine()

    public init(documents: [PackDocument]) {
        self.documents = documents
    }

    /// Every bundled pack.
    public static func bundled() throws -> PackProbe {
        try PackProbe(documents: PackRegistry.loadAllDocuments())
    }

    /// Packs not in `enabled` that would stop `command` on their own, each
    /// tried alone beside the day-one packs, in pack-id order.
    ///
    /// Each hit is a deny the pack's own rule gives (critical or high). A
    /// medium or low match lets the command run, so it is not a stop. Packs
    /// already on are left out: what they do is the verdict itself.
    public func offPacksThatWouldStop(_ command: ShellCommand, enabled: [PackID]) -> [OffPackHit] {
        let view = Normalize.matchingView(of: command).rawValue
        guard view.isEmpty == false else { return [] }
        let on = Set(enabled).union(dayOnePackIDs)
        let candidates = documents
            .filter { on.contains($0.id) == false }
            .filter { document in document.keywords.contains { QuickReject.keywordHits($0, in: view) } }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        guard candidates.isEmpty == false else { return [] }
        let base = documents.filter { dayOnePackIDs.contains($0.id) }
        let snapshots = (base + candidates).map(\.snapshot)
        guard let compiled = try? CompiledPacks<ICUCompiledPattern>.compile(packs: snapshots, using: engine) else {
            return []
        }
        return candidates.compactMap { candidate in
            let result = evaluate(
                EvaluationRequest(command: command, enabledPacks: dayOnePackIDs + [candidate.id]),
                packs: snapshots,
                engine: engine,
                compiled: compiled
            )
            guard case .deny(let deny) = result.decision, deny.ruleID.pack == candidate.id else { return nil }
            return OffPackHit(packID: candidate.id, ruleID: deny.ruleID)
        }
    }
}
