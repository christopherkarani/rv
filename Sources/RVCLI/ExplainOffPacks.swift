import RVDomain
import RVPolicy
import RVPresentation
import RVService

/// Packs that are off and would stop an explained command (G2).
///
/// `rv explain` evaluates only the packs in force, so a command the Redis
/// pack would stop read as a plain allow. When the verdict lets the
/// command run, this tries each bundled pack that is off, alone beside the
/// day-one packs, and lists the ones that would stop it with the command
/// that turns each on. Read-only: it never changes the verdict.
enum ExplainOffPacks {
    static func hits(result: EvaluationResult, command: ShellCommand, home: HomeDirectory?) -> [ExplainOffPack] {
        guard result.decision == .allow, let probe = try? PackProbe.bundled() else { return [] }
        let enabled = EvaluationWorld.walkedPackIDs(home: home).ids
        return rows(probe.offPacksThatWouldStop(command, enabled: enabled))
    }

    /// Pure core: one row per hit, with the command that turns its pack on.
    static func rows(_ hits: [OffPackHit]) -> [ExplainOffPack] {
        hits.map { hit in
            ExplainOffPack(packID: hit.packID, ruleID: hit.ruleID, turnOn: turnOnCommand(hit.packID))
        }
    }

    /// `rv protect redis`
    static func turnOnCommand(_ packID: PackID) -> String {
        ProtectTurnOn.command(packID)
    }
}
