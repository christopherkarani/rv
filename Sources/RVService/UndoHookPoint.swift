import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVUndo

/// Where rvd's decision path asks for an undo copy (H3). `GatedEvaluate`
/// calls `request` at the two moments a destructive command goes through
/// that rv would otherwise stop: an observe-mode would-be deny, and a deny
/// an allow-once grant (a terminal unlock or a review approval) let
/// through. Every other decision pays nothing: no I/O happens here, and
/// `UndoPlan` returns nil for anything that is not a reset, discard,
/// clean or delete. The copy itself runs with the gated effects
/// (`GatedEffect.keepCopy`), before the reply, inside `budget`.
enum UndoHookPoint {
    /// The longest a copy may take on the hook path.
    static let budget = UndoLimits.defaultBudget
    /// Hook budget left over for everything after the copy (effects,
    /// reply). Less than this left: no copy, the reply matters more.
    static let replyMargin: Duration = .milliseconds(2_500)
    /// Below this, a copy would only half finish: skip it.
    static let smallestUseful: Duration = .milliseconds(200)

    /// The copy to keep before `result`'s command runs, or nil.
    static func request(
        for result: EvaluationResult, command: ShellCommand, cwd: WorkingDirectory?, host: LedgerHost,
        reason: UndoReason, deadline: HookDeadline? = HookDeadline.current, now: ContinuousClock.Instant = .now
    ) -> UndoRequest? {
        guard case .hook(let hookHost) = host, let cwd else { return nil }
        guard let target = UndoPlan.target(for: result.analysis, cwd: cwd.rawValue) else { return nil }
        var budget = Self.budget
        if let deadline {
            budget = min(budget, deadline.expiresAt - now - replyMargin)
        }
        guard budget >= smallestUseful else { return nil }
        return UndoRequest(
            target: target, cwd: cwd.rawValue, command: LiveEventRedaction.command(command.rawValue, home: nil),
            host: hookHost.rawValue, reason: reason, budget: budget, deadline: now + budget)
    }

    /// Keeps the copy in the owner's store. Never fails the decision.
    static func keep(_ request: UndoRequest, home: HomeDirectory) {
        UndoKeeper.keep(request, in: UndoStore.inConfigDirectory(RVPolicyPaths.configDirectory(home: home)))
    }
}
