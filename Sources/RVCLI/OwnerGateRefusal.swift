import ArgumentParser
import Foundation
import RVPolicy

/// The one table of owner-gate refusals shared by `rv allow-once`, `rv egress
/// approve/deny`, `rv allowlist` mutations, and the workspace review queue.
///
/// A classifier, not typed throws: ceremony bodies call untyped stores and
/// `CLIOwnerAuth`, and `ctx.requireHome()` throws `ExitCode`, which must pass
/// through. `init?(_:)` returns nil for anything that is not a gate refusal.
enum OwnerGateRefusal: Error, Sendable, Equatable, CaseIterable {
    case ttyRequired
    case robotRefused
    case changedDuringReview
    case authRequired
    case throttled
    case storeUnavailable

    enum Subject: Sendable, CaseIterable {
        case grant
        case proposal
        case allowlistEntry
    }

    /// Exit code every gate refusal maps to.
    static let exitCode: Int32 = 2

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
            case .grant: return "grant changed during review; retry with a fresh code"
            case .proposal: return "proposal changed during review; retry"
            case .allowlistEntry: return "allowlist entry changed during review; retry"
            }
        case .authRequired: return "device-owner authentication required"
        case .throttled: return "too many authentication prompts; wait and retry"
        case .storeUnavailable: return "store unavailable"
        }
    }

    func message(command: String, subject: Subject) -> (text: String, exitCode: Int32) {
        ("rv \(command): \(text(subject: subject))\n", Self.exitCode)
    }
}

extension CommandContext {
    /// Gate refusal: one stderr line plus exit 2. Anything else, `ExitCode`
    /// included, is rethrown unchanged.
    func failOwnerGate(
        _ error: any Error,
        command: String,
        subject: OwnerGateRefusal.Subject
    ) throws -> Never {
        guard let refusal = OwnerGateRefusal(error) else { throw error }
        let message = refusal.message(command: command, subject: subject)
        try fail(message.text, exitCode: message.exitCode)
    }
}
