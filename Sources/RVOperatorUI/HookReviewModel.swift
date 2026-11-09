import Foundation
import RVIPC

#if canImport(RVXPC)
import RVXPC
#endif

/// Test seam over the hook-review bridge. Production uses
/// `XPCOperatorUIClient`; tests use a fake. DTOs only — no XPC types cross
/// this boundary. Separate protocol from `OperatorUIBridge` (launch) and
/// `OperatorActionUIBridge` (action): the three modes share one connection
/// and session, never state or vocabulary.
public protocol OperatorHookUIBridge: Sendable {
    func connect() async throws
    func hookList() async throws -> UIHookReviewListDTO
    func hookBind(approvalID: String) async throws -> UIHookChallengeBundleDTO
    func hookComplete(_ completion: UIHookCompletion) async throws -> UIHookStatusDTO
    func hookDeny(_ deny: UIHookDeny) async throws -> UIHookStatusDTO
    func hookCancel(approvalID: String) async throws -> UIHookStatusDTO
    func hookStatus(approvalID: String) async throws -> UIHookStatusDTO
}

#if canImport(XPC)
extension XPCOperatorUIClient: OperatorHookUIBridge {}
#endif

/// Hook-ask review state for one RVOperatorUI window. Distinct state type
/// from `OperatorReviewModel` (launch) and `OperatorActionReviewModel`
/// (action): selecting, binding, allowing, or denying here can never touch
/// another mode's review, and vice versa.
///
/// Passive by construction: nothing here prompts for authentication except
/// an explicit `allowOnce()` call from the Allow-once button. The bound
/// challenge is retained verbatim and its exact IDs are echoed back on
/// completion or deny; the model never substitutes, caches across
/// approvals, or completes a challenge it did not bind. Polling
/// (`maintain()`) only lists: it can surface arrivals, never authenticate.
@Observable
@MainActor
public final class OperatorHookReviewModel {
    public typealias Connection = ReviewConnection

    private var session = ReviewSession<HookReview>()
    private let bridge: any OperatorHookUIBridge
    private let authenticator: OperatorAuthenticator

    public var connection: Connection { session.connection }
    public var items: [UIHookReviewItemDTO] { session.items }
    public var selectedID: String? { session.selectedID }
    public var bound: UIHookChallengeBundleDTO? { session.bound }
    public var lastStatus: HookReviewStatus? { session.lastStatus }
    public var notice: String? { session.notice }
    public var authenticating: Bool { session.isAuthorizing }
    /// Approval IDs that arrived after the initial baseline and have not
    /// been opened yet. Drives the view's arrival signal (badge/bounce).
    public var unseenApprovalIDs: Set<String> { session.arrivals.unseen }

    public init(
        bridge: any OperatorHookUIBridge,
        authenticator: OperatorAuthenticator = OperatorAuthenticator()
    ) {
        self.bridge = bridge
        self.authenticator = authenticator
    }

    public func connect() async { await send(.connectRequested) }

    /// One poll tick for the view's refresh loop: redial while the bridge
    /// is unreachable (self-heals after an rvd outage), otherwise refresh.
    /// Lists only; never authenticates.
    public func maintain() async { await send(.maintainTick) }

    public func refresh() async { await send(.refreshRequested) }

    /// Selects a hook wait and binds its review challenge. Binding is
    /// server-idempotent: re-selecting returns the same live challenge.
    /// Binding never authenticates: it only opens the review for reading.
    public func select(_ id: String?) async { await send(.selectTapped(id)) }

    /// False when the bound wait can never allow-once (file/http
    /// actions carry no exact command). Nil from older servers means
    /// available, matching previous behavior.
    public var allowOnceAvailable: Bool {
        bound?.item.allowOnceAvailable ?? true
    }

    /// Explicit Allow-once tap: one fresh device-owner authentication, then
    /// completion echoes the EXACT retained challenge and approval IDs.
    /// Anything else (mismatch, tamper, replay) fails closed in rvd.
    /// A non-authenticated outcome (cancel, failure, unavailable) sends
    /// nothing: the server destroys the challenge for an unauthenticated
    /// completion, so reporting the outcome would burn the bound review
    /// the human can still retry. The selection stays bound.
    public func allowOnce() async { await send(.allowTapped) }

    /// Explicit Deny tap: denies the exact bound review without
    /// authenticating (deny grants nothing). Binds first when the review is
    /// selected but not yet bound, since deny addresses the live challenge.
    public func deny() async { await send(.denyTapped) }

    public func dismissNotice() {
        _ = session.reduce(.dismissNotice)
    }

    private func send(_ event: ReviewSession<HookReview>.Event) async {
        var queue = session.reduce(event)
        while !queue.isEmpty {
            let reply = await run(queue.removeFirst())
            queue += session.reduce(reply)
        }
    }

    private func run(_ command: ReviewSession<HookReview>.Command) async
        -> ReviewSession<HookReview>.Event
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
                return .listReplied(gen: gen, .success(try await bridge.hookList().items))
            } catch {
                return .listReplied(gen: gen, .failure(ReviewFailure(error)))
            }
        case .bind(let id, let ticket):
            do {
                return .bindReplied(id, ticket: ticket, .success(try await bridge.hookBind(approvalID: id)))
            } catch {
                return .bindReplied(id, ticket: ticket, .failure(ReviewFailure(error)))
            }
        case .authenticate(let bundle):
            let outcome = await authenticator.authenticate(reason: HookReview.authenticationReason)
            return .authenticated(challenge: bundle.challenge.challengeID, outcome)
        case .complete(let bundle, let outcome):
            let challenge = bundle.challenge.challengeID
            do {
                let status = try await bridge.hookComplete(UIHookCompletion(
                    challengeID: challenge, approvalID: bundle.item.approvalID,
                    outcome: outcome))
                return .completeReplied(challenge: challenge, .success(status.status))
            } catch {
                return .completeReplied(challenge: challenge, .failure(ReviewFailure(error)))
            }
        case .deny(let bundle):
            let id = bundle.item.approvalID
            do {
                let status = try await bridge.hookDeny(UIHookDeny(
                    challengeID: bundle.challenge.challengeID, approvalID: id))
                return .denyReplied(id, .success(status.status))
            } catch {
                return .denyReplied(id, .failure(ReviewFailure(error)))
            }
        case .cancel(let id):
            // Unreachable: hook review denies the bound challenge.
            return .denyReplied(id, .failure(.generic))
        }
    }
}
