import ArgumentParser
import Foundation
import RVIPC
import RVPolicy

/// The one table of owner-gate refusals shared by `rv allow-once`, `rv egress
/// approve/deny`, `rv allowlist` mutations, and the workspace review queue.
///
/// A classifier, not typed throws: ceremony bodies call untyped stores and
/// `CLIOwnerAuth`, and `ctx.requireHome()` throws `ExitCode`, which must pass
/// through. `init?(_:)` returns nil for anything that is not a gate refusal.
enum OwnerGateRefusal: Sendable, Equatable {
    case ttyRequired
    case robotRefused
    case changedDuringReview
    case authRequired
    case throttled
    case storeUnavailable
    /// rvd's owner check refused (declined, wrong password, locked out,
    /// another prompt open, no prompt possible). Only allow-once raises it.
    case notApproved(ConfirmOwnerActionReply)
    /// Too long to show in full in an owner prompt, so never approvable.
    case notShowable
    /// rvd reported a plant without saying it checked the owner the way
    /// this platform's rvd does. Not believed.
    case ownerCheckUnconfirmed
    /// rvd has no record of issuing the code, so it shows no prompt for it.
    case notIssuedByService

    enum Subject: Sendable, CaseIterable {
        /// `rv allow-once <code>`: redeeming a code into a grant.
        case grant
        /// `rv allow-once mint`: pre-arming a new code.
        case newCode
        case proposal
        case allowlistEntry
    }

    /// Exit code of a gate refusal that is not an owner-check refusal
    /// (TTY, format, store, a row that changed under review).
    static let exitCode: Int32 = 2

    /// The owner check refused or could not confirm the owner: EX_NOPERM,
    /// like every other owner-gated command (`OwnerConfirmation`). Other
    /// gate refusals keep `exitCode`.
    var exitCode: Int32 {
        switch self {
        case .authRequired, .throttled, .notApproved, .ownerCheckUnconfirmed:
            OwnerConfirmation.refusalExitCode
        case .ttyRequired, .robotRefused, .changedDuringReview, .storeUnavailable,
            .notShowable, .notIssuedByService:
            Self.exitCode
        }
    }

    init?(_ error: any Error) {
        switch error {
        case let error as AllowOnceError:
            switch error {
            case .ttyRequired: self = .ttyRequired
            case .robotRefused: self = .robotRefused
            case .redemptionChanged: self = .changedDuringReview
            case .lockFailed, .encodeFailed, .collision: self = .storeUnavailable
            case .unknownCode, .expired, .alreadySpent, .alreadyPending,
                .emptyCommand, .notUnlockable:
                return nil
            }
        case let error as AllowOnceAuthError:
            switch error {
            case .required: self = .authRequired
            case .throttled: self = .throttled
            }
        case let error as AllowOnceAttestError:
            switch error {
            case .notApproved(let reply): self = .notApproved(reply)
            case .notShowable: self = .notShowable
            case .ownerCheckUnconfirmed: self = .ownerCheckUnconfirmed
            case .notIssuedByService: self = .notIssuedByService
            // Reachability and caller identity, worded per site.
            case .serviceUnavailable, .serviceDenied:
                return nil
            }
        case let error as EgressReviewError:
            switch error {
            case .storeUnavailable: self = .storeUnavailable
            case .unknownProposal, .notAwaiting, .notNetworkProposal, .reasonRequired:
                return nil
            }
        case let error as AllowlistStoreError:
            switch error {
            case .lockFailed: self = .storeUnavailable
            }
        default:
            return nil
        }
    }

    func text(subject: Subject) -> String {
        switch self {
        case .ttyRequired: return "requires an interactive TTY (stdin and stdout)"
        case .robotRefused: return "--json/--robot refused"
        case .changedDuringReview:
            switch subject {
            case .grant, .newCode: return "grant changed during review; retry with a fresh code"
            case .proposal: return "proposal changed during review; retry"
            case .allowlistEntry: return "allowlist entry changed during review; retry"
            }
        case .authRequired: return "device-owner authentication required"
        case .throttled: return "too many authentication prompts; wait and retry"
        case .storeUnavailable: return "store unavailable"
        case .notApproved(let reply):
            return subject == .newCode
                ? AllowOnceCLI.mintNotApprovedMessage(reply)
                : AllowOnceCLI.notApprovedMessage(reply)
        case .notShowable: return AllowOnceCLI.notShowableMessage
        case .ownerCheckUnconfirmed:
            return "rvd did not say it checked the owner (an older rvd still running after an upgrade?); "
                + "nothing was allowed. Run rv service restart and try again"
        case .notIssuedByService:
            return subject == .newCode
                ? AllowOnceCLI.mintServiceDeniedMessage
                : "rvd did not issue this code (rvd restarted since it issued it, or the pending file was edited); "
                    + "rerun the command for a fresh code"
        }
    }

    func message(command: String, subject: Subject) -> String {
        "rv \(command): \(text(subject: subject))\n"
    }
}

extension CommandContext {
    /// Gate refusal: one stderr line plus its exit code (EX_NOPERM for an
    /// owner-check refusal, else 2). Anything else, `ExitCode` included, is
    /// rethrown unchanged.
    func failOwnerGate(
        _ error: any Error,
        command: String,
        subject: OwnerGateRefusal.Subject
    ) throws -> Never {
        guard let refusal = OwnerGateRefusal(error) else { throw error }
        try fail(refusal.message(command: command, subject: subject), exitCode: refusal.exitCode)
    }
}
