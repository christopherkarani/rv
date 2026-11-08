import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVPresentation
import RVTheme
import RVTUI
import RVWorkspaceTUI

/// Live stores behind the `rv tui` review pane: pending network proposals
/// (`rv egress pending`) and recent blocks (`rv blocks`).
///
/// This type adds no authority. Approve and deny enter
/// `EgressReviewRun.ownerApprove` / `ownerDeny`, the same doors as
/// `rv egress approve` / `rv egress deny`, so the local control boundary,
/// TTY and robot gates, prompt throttle, device-owner authentication, and
/// the post-prompt re-read all apply unchanged. Nothing here writes to
/// stdout or stderr: the TUI owns the screen, and every failure comes back
/// as text the pane shows.
struct WorkspaceReviewQueue: ReviewQueueSource {
    /// Newest blocks shown; the ledger itself keeps up to 200.
    static let blockLimit = 50
    static let homeMissing = "home directory unavailable"

    func load(now: Date) async -> ReviewLoadResult {
        guard let home = CLIProcess.home() else { return .failed(Self.homeMissing) }
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        let pending: [EgressProposalView]
        do {
            pending = try await EgressReviewRun.pending(store: EgressReviewRun.store(home: home), now: now)
        } catch {
            return .failed("egress store unavailable")
        }
        let loaded = EgressReviewRun.loadedSnapshot(configDirectory: configDirectory)
        let records = DenialLedger(configDirectory: configDirectory).records(asOf: now)
        return .loaded(
            pending.map { Self.item(for: $0, loaded: loaded) }
                + Self.blockItems(Array(records.prefix(Self.blockLimit)))
        )
    }

    func approve(egress id: String) async -> ReviewActionOutcome {
        guard CLIProcess.home() != nil else { return .refused("approve refused: \(Self.homeMissing)") }
        do {
            let view = try await EgressReviewRun.ownerApprove(id: ApprovalID(rawValue: id), ctx: Self.context("approve"))
            return .completed(
                "approved \(DisplayedText.field(view.host)):\(view.port) (live within seconds; no restart)"
            )
        } catch {
            return .refused("approve refused: \(Self.refusal(error))")
        }
    }

    func deny(egress id: String, reason: String) async -> ReviewActionOutcome {
        guard CLIProcess.home() != nil else { return .refused("deny refused: \(Self.homeMissing)") }
        do {
            let view = try await EgressReviewRun.ownerDeny(
                id: ApprovalID(rawValue: id), reason: reason, ctx: Self.context("deny")
            )
            return .completed("denied \(DisplayedText.field(view.host)):\(view.port)")
        } catch {
            return .refused("deny refused: \(Self.refusal(error))")
        }
    }

    /// The same context `rv egress approve` builds without format flags:
    /// the live TTY and CI probe, never a robot request.
    private static func context(_ verb: String) -> CommandContext {
        CommandContext.current(command: "egress \(verb)", json: false, robot: false, plain: false, noColor: false)
    }

    /// The `rv egress approve/deny` refusal wording for each ceremony error.
    /// Anything unrecognized still reads as a refusal, never a success.
    static func refusal(_ error: Error) -> String {
        switch error {
        case let error as ValidationError: return error.message
        case AllowOnceError.ttyRequired: return "requires an interactive TTY (stdin and stdout)"
        case AllowOnceError.robotRefused: return "robot output refused"
        case AllowOnceError.redemptionChanged: return "proposal changed during review; retry"
        case EgressReviewError.unknownProposal: return "unknown proposal"
        case EgressReviewError.notNetworkProposal: return "not a network proposal"
        case EgressReviewError.notAwaiting(let state): return "proposal is \(state)"
        case EgressReviewError.reasonRequired: return "a reason is required (one line, 500 chars)"
        case EgressReviewError.storeUnavailable: return "store unavailable"
        case AllowOnceAuthError.required: return "device-owner authentication required"
        case AllowOnceAuthError.throttled: return "too many authentication prompts; wait and retry"
        default: return "unexpected error"
        }
    }

    static func item(for view: EgressProposalView, loaded: EgressLoadedSnapshot?) -> ReviewItem {
        ReviewItem(
            id: .egress(view.id),
            kind: .pendingEgress,
            at: view.createdAt,
            summary: "\(DisplayedText.field(view.host)):\(view.port)",
            detail: EgressReviewRun.prettyShow(view, rejectionReason: nil, loaded: loaded)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { $0.isEmpty == false }
        )
    }

    /// Ledger rows have no id; one is derived from the row's fields plus
    /// an occurrence count, so identical rows stay distinct and stable.
    static func blockItems(_ records: [DenialLedgerRecord]) -> [ReviewItem] {
        var seen: [String: Int] = [:]
        let palette = Palette(for: ColorCapability(colorsEnabled: false))
        return records.map { record in
            let key = [
                String(record.timestamp.timeIntervalSince1970), record.host.rawValue,
                record.tool.rawValue, record.ruleID.rawValue, record.path,
            ].joined(separator: "|")
            let occurrence = seen[key, default: 0]
            seen[key] = occurrence + 1
            let path = record.path.isEmpty ? "" : "  \(DisplayedText.field(record.path))"
            return ReviewItem(
                id: .block("\(key)#\(occurrence)"),
                kind: .block,
                at: record.timestamp,
                summary: "\(DisplayedText.field(record.ruleID.slashDisplay))  \(record.tool.rawValue)\(path)",
                detail: ExplainRenderer().render(explainModel(for: record), palette: palette)
            )
        }
    }

    /// The explain view model for one recorded block. The ledger keeps no
    /// argv and no pack reason, so those read as not recorded rather than
    /// being re-derived.
    static func explainModel(for record: DenialLedgerRecord) -> ExplainViewModel {
        let fact = "\(record.tool.rawValue) blocked (\(record.category.rawValue))"
        return ExplainViewModel(
            command: ShellCommand(rawValue: "(not recorded)"),
            normalized: "(not recorded)",
            decision: .deny(Deny(ruleID: record.ruleID, reason: fact)),
            packID: record.ruleID.pack,
            ruleID: record.ruleID,
            fact: fact,
            nextAction: denyNextAction,
            steps: [],
            suggestions: suggestions(for: record.ruleID),
            semantic: ExplainSemanticView(
                action: record.tool.rawValue,
                scope: record.host.rawValue,
                path: record.path.isEmpty ? nil : record.path,
                category: record.category.rawValue
            )
        )
    }
}
