import Foundation
import RVIPC

/// Launch review: cancel by ID, never binds to deny, every authentication
/// outcome is reported to the server.
enum LaunchReview: ReviewMode {
    typealias ID = UUID
    typealias Item = UIReviewItemDTO
    typealias Bundle = UIChallengeBundleDTO
    typealias Status = WorkspaceOperationStatus

    static func id(of item: UIReviewItemDTO) -> UUID { item.operationID }
    static func id(of bundle: UIChallengeBundleDTO) -> UUID { bundle.item.operationID }
    static func challengeID(of bundle: UIChallengeBundleDTO) -> UUID {
        bundle.challenge.challengeID
    }

    static func isTerminal(_ status: WorkspaceOperationStatus) -> Bool {
        // Exhaustive: a new status breaks this switch until classified.
        switch status {
        case .authorized, .consumed, .cancelled, .expired, .invalidated, .failed:
            return true
        case .pendingReview, .awaitingAuthentication, .unknown:
            return false
        }
    }

    static var denyStrategy: DenyStrategy { .cancelByID }

    /// Fixed wording: server-supplied display names must not shape the
    /// authentication prompt. The trusted review window already shows
    /// exactly what is under review; the prompt proves presence only.
    static var authenticationReason: String {
        "Authenticate to authorize the selected workspace launch."
    }
}

/// Action review: deny the exact bound challenge (binding first if needed).
enum ActionReview: ReviewMode {
    typealias ID = UUID
    typealias Item = UIActionReviewItemDTO
    typealias Bundle = UIActionChallengeBundleDTO
    typealias Status = HostActionApprovalStatus

    static func id(of item: UIActionReviewItemDTO) -> UUID { item.approvalID }
    static func id(of bundle: UIActionChallengeBundleDTO) -> UUID { bundle.item.approvalID }
    static func challengeID(of bundle: UIActionChallengeBundleDTO) -> UUID {
        bundle.challenge.challengeID
    }

    static func isTerminal(_ status: HostActionApprovalStatus) -> Bool {
        // Exhaustive: a new status breaks this switch until classified.
        switch status {
        case .authorized, .consumed, .denied, .cancelled, .expired, .invalidated, .failed:
            return true
        case .pending, .awaitingAuthentication, .unknown:
            return false
        }
    }

    static var denyStrategy: DenyStrategy { .denyBoundChallenge }

    /// Distinct from the launch prompt so the human can tell which type of
    /// authority the authentication is for.
    static var authenticationReason: String {
        "Authenticate to allow the selected agent action once."
    }
}

/// Hook review: like action review, plus the allow-once gate, per-outcome
/// notices for unauthenticated outcomes (nothing is sent: the server destroys
/// the challenge on an unauthenticated completion), and arrival tracking.
enum HookReview: ReviewMode {
    typealias ID = String
    typealias Item = UIHookReviewItemDTO
    typealias Bundle = UIHookChallengeBundleDTO
    typealias Status = HookReviewStatus

    static func id(of item: UIHookReviewItemDTO) -> String { item.approvalID }
    static func id(of bundle: UIHookChallengeBundleDTO) -> String { bundle.item.approvalID }
    static func challengeID(of bundle: UIHookChallengeBundleDTO) -> UUID {
        bundle.challenge.challengeID
    }

    static func isTerminal(_ status: HookReviewStatus) -> Bool {
        // Exhaustive: a new status breaks this switch until classified.
        switch status {
        case .allowedOnce, .ruleCreated, .denied, .consumed, .expired, .canceled, .timedOut:
            return true
        case .awaitingHuman, .awaitingAuthentication, .unknown:
            return false
        }
    }

    static var denyStrategy: DenyStrategy { .denyBoundChallenge }
    static var tracksArrivals: Bool { true }

    /// Distinct from the launch and action prompts so the human can tell
    /// which type of authority the authentication is for.
    static var authenticationReason: String {
        "Authenticate to allow the selected coding-agent command once."
    }

    /// Nil from older servers means available, matching previous behavior.
    static func unavailableNotice(_ bundle: UIHookChallengeBundleDTO) -> String? {
        (bundle.item.allowOnceAvailable ?? true)
            ? nil : "Allow once is unavailable for this request."
    }

    static func notAuthenticatedNotice(_ outcome: UIAuthenticationOutcome) -> String? {
        switch outcome {
        case .authenticated:
            return nil
        case .cancelled:
            return "Authentication cancelled. The review is still open."
        case .unavailable:
            return "Device-owner authentication is unavailable."
        case .timedOut:
            return "Authentication timed out. The review is still open."
        case .invalidated:
            return "Authentication was invalidated. The review is still open."
        case .failed:
            return "Authentication failed. The review is still open."
        }
    }
}
