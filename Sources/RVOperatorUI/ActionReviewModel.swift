import Foundation
import RVIPC

#if canImport(RVXPC)
import RVXPC
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
    public typealias Connection = ReviewConnection

    private var session = ReviewSession<ActionReview>()
    private let bridge: any OperatorActionUIBridge
    private let authenticator: OperatorAuthenticator

    public var connection: Connection { session.connection }
    public var items: [UIActionReviewItemDTO] { session.items }
    public var selectedID: UUID? { session.selectedID }
    public var bound: UIActionChallengeBundleDTO? { session.bound }
    public var lastStatus: HostActionApprovalStatus? { session.lastStatus }
    public var notice: String? { session.notice }
    public var authenticating: Bool { session.isAuthorizing }

    public init(
        bridge: any OperatorActionUIBridge,
        authenticator: OperatorAuthenticator = OperatorAuthenticator()
    ) {
        self.bridge = bridge
        self.authenticator = authenticator
    }

    public func connect() async { await send(.connectRequested) }

    public func refresh() async { await send(.refreshRequested) }

    /// Selects an approval and binds its review challenge. Binding is
    /// server-idempotent: re-selecting returns the same live challenge.
    /// Binding never authenticates: it only opens the review for reading.
    public func select(_ id: UUID?) async { await send(.selectTapped(id)) }

    /// Explicit Allow-once tap: one fresh device-owner authentication, then
    /// completion echoes the EXACT retained challenge and approval IDs.
    /// Anything else (mismatch, tamper, replay) fails closed in rvd.
    public func allowOnce() async { await send(.allowTapped) }

    /// Explicit Deny tap: denies the exact bound review without
    /// authenticating (deny grants nothing). Binds first when the review is
    /// selected but not yet bound, since deny addresses the live challenge.
    public func deny() async { await send(.denyTapped) }

    public func dismissNotice() {
        _ = session.reduce(.dismissNotice)
    }

    private func send(_ event: ReviewSession<ActionReview>.Event) async {
        var queue = session.reduce(event)
        while !queue.isEmpty {
            let reply = await run(queue.removeFirst())
            queue += session.reduce(reply)
        }
    }

    private func run(_ command: ReviewSession<ActionReview>.Command) async
        -> ReviewSession<ActionReview>.Event
    {
        switch command {
        case .connect:
            do {
                try await bridge.connect()
                return .connectReplied(nil)
            } catch {
                return .connectReplied(ReviewFailure(error))
            }
        case .list(let gen):
            do {
                return .listReplied(gen: gen, .success(try await bridge.actionList().items))
            } catch {
                return .listReplied(gen: gen, .failure(ReviewFailure(error)))
            }
        case .bind(let id, let ticket):
            do {
                return .bindReplied(id, ticket: ticket, .success(try await bridge.actionBind(approvalID: id)))
            } catch {
                return .bindReplied(id, ticket: ticket, .failure(ReviewFailure(error)))
            }
        case .authenticate(let bundle):
            let outcome = await authenticator.authenticate(reason: ActionReview.authenticationReason)
            return .authenticated(challenge: bundle.challenge.challengeID, outcome)
        case .complete(let bundle, let outcome):
            let challenge = bundle.challenge.challengeID
            do {
                let status = try await bridge.actionComplete(UIActionCompletion(
                    challengeID: challenge, approvalID: bundle.item.approvalID,
                    outcome: outcome))
                return .completeReplied(challenge: challenge, .success(status.status))
            } catch {
                return .completeReplied(challenge: challenge, .failure(ReviewFailure(error)))
            }
        case .deny(let bundle):
            let id = bundle.item.approvalID
            do {
                let status = try await bridge.actionDeny(UIActionDeny(
                    challengeID: bundle.challenge.challengeID, approvalID: id))
                return .denyReplied(id, .success(status.status))
            } catch {
                return .denyReplied(id, .failure(ReviewFailure(error)))
            }
        case .cancel(let id):
            // Unreachable: action review denies the bound challenge.
            return .denyReplied(id, .failure(.generic))
        }
    }
}
