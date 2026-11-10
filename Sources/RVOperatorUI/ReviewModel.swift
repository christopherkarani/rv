import Foundation
import RVIPC

#if canImport(RVXPC)
import RVXPC
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
    public typealias Connection = ReviewConnection

    private var session = ReviewSession<LaunchReview>()
    private let bridge: any OperatorUIBridge
    private let authenticator: OperatorAuthenticator

    public var connection: Connection { session.connection }
    public var items: [UIReviewItemDTO] { session.items }
    public var selectedID: UUID? { session.selectedID }
    public var bound: UIChallengeBundleDTO? { session.bound }
    public var lastStatus: WorkspaceOperationStatus? { session.lastStatus }
    public var notice: String? { session.notice }
    public var authenticating: Bool { session.isAuthorizing }

    public init(
        bridge: any OperatorUIBridge,
        authenticator: OperatorAuthenticator = OperatorAuthenticator()
    ) {
        self.bridge = bridge
        self.authenticator = authenticator
    }

    public func connect() async { await send(.connectRequested) }

    public func refresh() async { await send(.refreshRequested) }

    /// Selects an operation and binds its review challenge. Binding is
    /// server-idempotent: re-selecting returns the same live challenge.
    public func select(_ id: UUID?) async { await send(.selectTapped(id)) }

    /// Explicit Authorize tap: one fresh device-owner authentication, then
    /// completion echoes the EXACT retained challenge and operation IDs.
    /// Anything else (mismatch, tamper, replay) fails closed in rvd.
    public func authorize() async { await send(.allowTapped) }

    public func dismissNotice() {
        _ = session.reduce(.dismissNotice)
    }

    /// Explicit Deny tap: cancels the selected review. Works bound or not.
    public func deny() async { await send(.denyTapped) }

    private func send(_ event: ReviewSession<LaunchReview>.Event) async {
        var queue = session.reduce(event)
        while !queue.isEmpty {
            let reply = await run(queue.removeFirst())
            queue += session.reduce(reply)
        }
    }

    private func run(_ command: ReviewSession<LaunchReview>.Command) async
        -> ReviewSession<LaunchReview>.Event
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
                return .listReplied(gen: gen, .success(try await bridge.list().items))
            } catch {
                return .listReplied(gen: gen, .failure(ReviewFailure(error)))
            }
        case .bind(let id, let ticket):
            do {
                return .bindReplied(id, ticket: ticket, .success(try await bridge.bind(operationID: id)))
            } catch {
                return .bindReplied(id, ticket: ticket, .failure(ReviewFailure(error)))
            }
        case .authenticate(let bundle):
            let outcome = await authenticator.authenticate(reason: LaunchReview.authenticationReason)
            return .authenticated(challenge: bundle.challenge.challengeID, outcome)
        case .complete(let bundle, let outcome):
            let challenge = bundle.challenge.challengeID
            do {
                let status = try await bridge.complete(UIOperatorCompletion(
                    challengeID: challenge, operationID: bundle.item.operationID,
                    outcome: outcome))
                return .completeReplied(challenge: challenge, .success(status.status))
            } catch {
                return .completeReplied(challenge: challenge, .failure(ReviewFailure(error)))
            }
        case .cancel(let id):
            do {
                return .denyReplied(id, .success(try await bridge.cancel(operationID: id).status))
            } catch {
                return .denyReplied(id, .failure(ReviewFailure(error)))
            }
        case .deny(let bundle):
            // Unreachable: launch denies by cancel(ID).
            return .denyReplied(bundle.item.operationID, .failure(.generic))
        }
    }
}
