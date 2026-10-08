import Foundation
import RVIPC

#if canImport(RVService)
import RVService
#endif

/// Test seam over the UI bridge. Production uses `XPCOperatorUIClient`;
/// tests use a fake. DTOs only — no XPC types cross this boundary.
public protocol OperatorUIBridge: Sendable {
    func connect() async throws
    func list() async throws -> UIReviewListDTO
    func bind(operationID: UUID) async throws -> UIChallengeBundleDTO
    func complete(_ completion: UIOperatorCompletion) async throws -> UIOperationStatusDTO
    func cancel(operationID: UUID) async throws -> UIOperationStatusDTO
    func status(operationID: UUID) async throws -> UIOperationStatusDTO
}

#if canImport(XPC)
extension XPCOperatorUIClient: OperatorUIBridge {}
#endif

/// Review state for one RVOperatorUI window. Passive by construction: nothing
/// here prompts for authentication except an explicit `authorize()` call from
/// the Authorize button. The bound challenge is retained verbatim and its
/// exact IDs are echoed back on completion; the model never substitutes,
/// caches across operations, or completes a challenge it did not bind.
@Observable
@MainActor
public final class OperatorReviewModel {
    public enum Connection: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    public private(set) var connection: Connection = .disconnected
    public private(set) var items: [UIReviewItemDTO] = []
    public private(set) var selectedID: UUID?
    public private(set) var bound: UIChallengeBundleDTO?
    public private(set) var lastStatus: WorkspaceOperationStatus?
    public private(set) var notice: String?
    public private(set) var authenticating = false

    private let bridge: any OperatorUIBridge
    private let authenticator: OperatorAuthenticator

    public init(
        bridge: any OperatorUIBridge,
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
            items = try await bridge.list().items
            if let selectedID, !items.contains(where: { $0.operationID == selectedID }) {
                clearSelection()
            } else if let current = bound,
                !items.contains(where: { $0.operationID == current.item.operationID }) {
                bound = nil
            }
            notice = nil
        } catch {
            notice = describe(error)
        }
    }

    /// Selects an operation and binds its review challenge. Binding is
    /// server-idempotent: re-selecting returns the same live challenge.
    public func select(_ id: UUID?) async {
        guard id != selectedID, !authenticating else { return }
        clearSelection()
        guard let id, connection == .connected else { return }
        selectedID = id
        do {
            bound = try await bridge.bind(operationID: id)
            notice = nil
        } catch {
            notice = describe(error)
        }
    }

    /// Explicit Authorize tap: one fresh device-owner authentication, then
    /// completion echoes the EXACT retained challenge and operation IDs.
    /// Anything else (mismatch, tamper, replay) fails closed in rvd.
    public func authorize() async {
        guard let bound, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let outcome = await authenticator.authenticate(reason: reason(for: bound.item))
        do {
            let status = try await bridge.complete(UIOperatorCompletion(
                challengeID: bound.challenge.challengeID,
                operationID: bound.item.operationID,
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

    public func dismissNotice() {
        notice = nil
    }

    /// Explicit Deny tap: cancels the selected review. Works bound or not.
    public func deny() async {
        guard let selectedID, !authenticating else { return }
        do {
            let status = try await bridge.cancel(operationID: selectedID)
            lastStatus = status.status
            clearSelection()
            await refresh()
        } catch {
            notice = describe(error)
        }
    }

    private func clearSelection() {
        selectedID = nil
        bound = nil
    }

    private static func isTerminal(_ status: WorkspaceOperationStatus) -> Bool {
        // Exhaustive: a new status breaks this switch until classified.
        switch status {
        case .authorized, .consumed, .cancelled, .expired, .invalidated, .failed:
            return true
        case .pendingReview, .awaitingAuthentication, .unknown:
            return false
        }
    }

    private func reason(for _: UIReviewItemDTO) -> String {
        // Fixed wording: server-supplied display names must not shape the
        // authentication prompt. The trusted review window already shows
        // exactly what is under review; the prompt proves presence only.
        "Authenticate to authorize the selected workspace launch."
    }

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
