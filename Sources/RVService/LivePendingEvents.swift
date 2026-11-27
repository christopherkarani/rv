import Foundation
import RVDomain
import RVIPC

/// Asks and resolutions for the live event bus: rvd's pending store
/// already announces every row change (`PendingApprovalCoordinating.events`);
/// this forwards each one, projected the way `pendingList` projects rows
/// (no command text), to the bus.
enum LivePendingEvents {
    /// Starts forwarding `pending`'s events to `bus` for the life of the
    /// store. The returned task finishes once the forwarder is subscribed:
    /// a row change after that is never missed.
    static func forward(_ pending: any PendingApprovalCoordinating, to bus: LiveEventBus) -> Task<Void, Never> {
        let subscribed = Task { await pending.events() }
        Task.detached(priority: .utility) {
            for await event in await subscribed.value {
                guard let (payload, time) = payload(for: event) else { continue }
                bus.publish(payload, at: time)
            }
        }
        return Task { _ = await subscribed.value }
    }

    /// The bus payload for one store event and the time it happened. Pure.
    static func payload(for event: PendingApprovalEvent) -> (LiveEventPayload, Date)? {
        switch event {
        case .created(let row):
            guard case .awaitingHuman = row.state else { return nil }
            return (.ask(LiveAsk(item: PendingListProjection.item(from: row))), row.createdAt)
        case .resolved(let row), .expired(let row), .canceled(let row), .timedOut(let row), .consumed(let row):
            guard let (outcome, time) = resolution(of: row.state) else { return nil }
            return (.resolution(LiveResolution(id: row.id, host: row.identity.agent, outcome: outcome)), time)
        }
    }

    private static func resolution(of state: PendingApprovalState) -> (LiveResolutionOutcome, Date)? {
        switch state {
        case .awaitingHuman:
            return nil
        case .resolved(let resolution):
            return (outcome(of: resolution.decision), resolution.resolvedAt)
        case .consumed(_, let at):
            return (.consumed, at)
        case .expired(let at):
            return (.expired, at)
        case .canceled(let at):
            return (.canceled, at)
        case .timedOut(let ending):
            return (.timedOut, ending.at)
        }
    }

    private static func outcome(of decision: ApprovalDecision) -> LiveResolutionOutcome {
        switch decision {
        case .allowOnce: .allowOnce
        case .createRule: .createRule
        case .deny: .deny
        }
    }
}
