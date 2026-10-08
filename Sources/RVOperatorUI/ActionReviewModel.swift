import Foundation
import RVIPC

#if canImport(RVService)
import RVService
#endif

/// Test seam over the action-review bridge. Production uses
/// `XPCOperatorUIClient`; tests use a fake. DTOs only — no XPC types cross
/// this boundary. Separate protocol from `OperatorUIBridge` (launch): the
/// two modes share one connection and session, never state or vocabulary.
public protocol OperatorActionUIBridge: Sendable {
    func connect() async throws
    func actionList() async throws -> UIActionReviewListDTO
    func actionBind(approvalID: UUID) async throws -> UIActionChallengeBundleDTO
    func actionComplete(_ completion: UIActionCompletion) async throws -> UIActionStatusDTO
    func actionDeny(_ deny: UIActionDeny) async throws -> UIActionStatusDTO
    func actionCancel(approvalID: UUID) async throws -> UIActionStatusDTO
    func actionStatus(approvalID: UUID) async throws -> UIActionStatusDTO
}

#if canImport(XPC)
extension XPCOperatorUIClient: OperatorActionUIBridge {}
#endif

/// Action-approval review state for one RVOperatorUI window. Distinct state
/// type from `OperatorReviewModel` (launch): selecting, binding, allowing,
/// or denying here can never touch a launch review, and vice versa.
///
/// Passive by construction: nothing here prompts for authentication except
/// an explicit `allowOnce()` call from the Allow-once button. The bound
/// challenge is retained verbatim and its exact IDs are echoed back on
/// completion or deny; the model never substitutes, caches across
/// approvals, or completes a challenge it did not bind.
@Observable
@MainActor
public final class OperatorActionReviewModel {
    public enum Connection: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    public private(set) var connection: Connection = .disconnected
    public private(set) var items: [UIActionReviewItemDTO] = []
    public private(set) var selectedID: UUID?
    public private(set) var bound: UIActionChallengeBundleDTO?
    public private(set) var lastStatus: HostActionApprovalStatus?
    public private(set) var notice: String?
    public private(set) var authenticating = false

    private let bridge: any OperatorActionUIBridge
    private let authenticator: OperatorAuthenticator

    public init(
        bridge: any OperatorActionUIBridge,
        authenticator: OperatorAuthenticator = OperatorAuthenticator()
    ) {
        self.bridge = bridge
        self.authenticator = authenticator
    }

    public func connect() async {
        guard connection != .connecting, connection != .connected else { return }
        connection = .connecting
        notice = nil
        do {
            try await bridge.connect()
            connection = .connected
            await refresh()
        } catch {
            connection = .failed(describe(error))
        }
    }

    public func refresh() async {
        guard connection == .connected else { return }
        do {
            items = try await bridge.actionList().items
            if let selectedID, !items.contains(where: { $0.approvalID == selectedID }) {
                clearSelection()
            } else if let current = bound,
                !items.contains(where: { $0.approvalID == current.item.approvalID }) {
                bound = nil
            }
            notice = nil
        } catch {
            notice = describe(error)
        }
    }

    /// Selects an approval and binds its review challenge. Binding is
    /// server-idempotent: re-selecting returns the same live challenge.
    /// Binding never authenticates: it only opens the review for reading.
    public func select(_ id: UUID?) async {
        guard id != selectedID, !authenticating else { return }
        clearSelection()
        guard let id, connection == .connected else { return }
        selectedID = id
        do {
            bound = try await bridge.actionBind(approvalID: id)
            notice = nil
        } catch {
            notice = describe(error)
        }
    }

    /// Explicit Allow-once tap: one fresh device-owner authentication, then
    /// completion echoes the EXACT retained challenge and approval IDs.
    /// Anything else (mismatch, tamper, replay) fails closed in rvd.
    public func allowOnce() async {
        guard let bound, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let outcome = await authenticator.authenticate(reason: Self.allowReason)
        do {
            let status = try await bridge.actionComplete(UIActionCompletion(
                challengeID: bound.challenge.challengeID,
                approvalID: bound.item.approvalID,
                outcome: outcome))
            lastStatus = status.status
            if Self.isTerminal(status.status) {
                clearSelection()
            }
            await refresh()
        } catch {
            notice = describe(error)
        }
    }

    /// Explicit Deny tap: denies the exact bound review without
    /// authenticating (deny grants nothing). Binds first when the review is
    /// selected but not yet bound, since deny addresses the live challenge.
    public func deny() async {
        guard let selectedID, !authenticating else { return }
        do {
            if bound == nil {
                bound = try await bridge.actionBind(approvalID: selectedID)
            }
            guard let bound else {
                notice = "Request failed."
                return
            }
            let status = try await bridge.actionDeny(UIActionDeny(
                challengeID: bound.challenge.challengeID,
                approvalID: bound.item.approvalID))
            lastStatus = status.status
            clearSelection()
            await refresh()
        } catch {
            notice = describe(error)
        }
    }

    public func dismissNotice() {
        notice = nil
    }

    private func clearSelection() {
        selectedID = nil
        bound = nil
    }

    private static func isTerminal(_ status: HostActionApprovalStatus) -> Bool {
        // Exhaustive: a new status breaks this switch until classified.
        switch status {
        case .authorized, .consumed, .denied, .cancelled, .expired, .invalidated, .failed:
            return true
        case .pending, .awaitingAuthentication, .unknown:
            return false
        }
    }

    /// Fixed wording: server-supplied display names must not shape the
    /// authentication prompt. The trusted review window already shows
    /// exactly what is under review; the prompt proves presence only.
    /// Distinct from the launch prompt so the human can tell which type of
    /// authority the authentication is for.
    private static let allowReason = "Authenticate to allow the selected agent action once."

    private func describe(_ error: any Error) -> String {
        #if canImport(XPC)
        if let error = error as? XPCOperatorUIClientError {
            switch error {
            case .denied:
                return "Denied: review is no longer valid. Refresh and rebind."
            case .authenticationFailed:
                return "Service identity check failed. Is rvd running?"
            case .connectFailed:
                return "Lost connection to rvd."
            case .protocolMismatch:
                return "Unexpected reply from rvd."
            case .cancelled:
                return "Cancelled."
            }
        }
        #endif
        return "Request failed."
    }
}
