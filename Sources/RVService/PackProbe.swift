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
/// for `rv explain` ("a rule in database.redis matches").
///
/// Read-only and advisory: it runs `evaluateWithSemantics` (the pack
/// evaluate plus the semantic analyzers, as the hook door does) on a pack set
/// of the caller's choosing and never changes a verdict. Patterns compile
/// on demand, and only for packs a command could reach (one of their
/// keywords is in its matching view: the engine skips a pack otherwise).
public struct PackProbe: Sendable {
    private let documents: [PackDocument]
    private let engine = ICUPatternEngine()

    public init(documents: [PackDocument]) {
        self.documents = documents
    }

    /// Every pack this probe knows, in id order.
    public var packIDs: [PackID] { documents.map(\.id).sorted { $0.rawValue < $1.rawValue } }

    /// Every bundled pack.
    public static func bundled() throws -> PackProbe {
        try PackProbe(documents: PackRegistry.loadAllDocuments())
    }

    /// Packs not in `enabled` that would stop `command` on their own, each
    /// tried alone beside the day-one packs, in pack-id order.
    ///
    /// Each hit is a deny the pack's own rule gives (critical or high). A
    /// medium or low match lets the command run, so it is not a stop. Packs
    /// already on are left out: what they do is the verdict itself. The
    /// owner's allowlist and typed policy rules are not applied, so a hit
    /// says a rule matches, not that the hook would stop the command.
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
            let result = evaluateWithSemantics(
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

/// One rule's examples, run (`rv packs test`).
public struct RuleExampleRun: Equatable, Sendable {
    /// An example that did not do what its label says.
    public struct Failure: Equatable, Sendable {
        public enum Label: String, Sendable {
            case stop
            case allow
        }

        public var label: Label
        public var command: String
        /// What rv did instead (`ran`, `stopped by core.git:reset-hard`).
        public var got: String

        public init(label: Label, command: String, got: String) {
            self.label = label
            self.command = command
            self.got = got
        }
    }

    public var ruleID: RuleID
    public var stops: Int
    public var allows: Int
    public var failures: [Failure]

    /// No example to run: the rule has none (it cannot be reached from a
    /// command, such as a placeholder the semantic analyzers emit).
    public var hasExamples: Bool { stops + allows > 0 }
    public var passed: Bool { failures.isEmpty }
}

extension PackProbe {
    /// Runs every example of `packID`'s rules with the pack on beside the
    /// day-one packs, as `RuleGuidanceTests` does for the whole catalog:
    ///
    /// - a `stop` example must make the rule fire (a critical or high rule
    ///   stops it, a medium or low one lets it run and records the match),
    ///   or be stopped by another rule while the rule's own pattern matches
    ///   it (a rule another rule shadows);
    /// - an `allow` example must run under the pack evaluate and the hook
    ///   door, and the rule must not fire on either.
    ///
    /// Nil when no bundled pack has that id.
    public func runExamples(of packID: PackID) -> [RuleExampleRun]? {
        guard let document = documents.first(where: { $0.id == packID }) else { return nil }
        let base = documents.filter { dayOnePackIDs.contains($0.id) && $0.id != packID }
        let snapshots = (base + [document]).map(\.snapshot)
        let enabled = dayOnePackIDs.contains(packID) ? dayOnePackIDs : dayOnePackIDs + [packID]
        guard let compiled = try? CompiledPacks<ICUCompiledPattern>.compile(packs: snapshots, using: engine) else {
            return nil
        }
        let rules = compiled.packs.first { $0.snapshot.id == packID }?.destructive ?? []
        return zip(document.destructive, document.guidance).map { rule, guidance in
            let id = guidance.ruleID
            func request(_ command: String) -> EvaluationRequest {
                EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: enabled)
            }
            var failures: [RuleExampleRun.Failure] = []
            for command in guidance.examples.stop {
                let result = evaluate(request(command), packs: snapshots, engine: engine, compiled: compiled)
                let denied = if case .deny = result.decision { true } else { false }
                let own = result.outcome.explainRuleID == id && rule.severity.blocksByDefault == denied
                let ownPattern = rules.first { $0.rule.name == id.pattern }.map {
                    engine.matches($0.compiled, in: Normalize.matchingView(of: command).rawValue)
                } ?? false
                let shadowed = denied && result.outcome.explainRuleID != id && ownPattern
                if own == false && shadowed == false {
                    failures.append(.init(label: .stop, command: command, got: Self.describe(result)))
                }
            }
            for command in guidance.examples.allow {
                let pin = evaluate(request(command), packs: snapshots, engine: engine, compiled: compiled)
                let door = evaluateWithSemantics(request(command), packs: snapshots, engine: engine, compiled: compiled)
                let firing = [pin, door].first { $0.decision != .allow || $0.outcome.explainRuleID == id }
                if let firing {
                    failures.append(.init(label: .allow, command: command, got: Self.describe(firing)))
                }
            }
            return RuleExampleRun(
                ruleID: id, stops: guidance.examples.stop.count, allows: guidance.examples.allow.count,
                failures: failures)
        }
    }

    /// `ran`, `ran, matched database.redis:flushdb`, `stopped by core.git:reset-hard`.
    static func describe(_ result: EvaluationResult) -> String {
        switch result.decision {
        case .allow:
            return result.outcome.explainRuleID.map { "ran, matched \($0.rawValue)" } ?? "ran"
        case .deny(let deny):
            return "stopped by \(deny.ruleID.rawValue)"
        case .indeterminate(let reason):
            return "could not be checked (\(reason.rawValue))"
        }
    }
}
