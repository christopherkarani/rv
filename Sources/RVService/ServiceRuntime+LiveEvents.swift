import Foundation
import RVIPC

/// `events` dispatch: the long poll and what each caller may see. Kept out
/// of `ServiceRuntime.swift`; the runtime only owns the bus.
extension ServiceRuntime {
    /// `events` on a same-user socket session. Each socket listener sets
    /// `enabled` only after the kernel attested the peer's uid equals
    /// rvd's: Linux captures it (`SO_PEERCRED`) into the context, checked
    /// again here; macOS checks `getpeereid` at accept and carries no
    /// peer, so the listener's check is the owner check.
    static func socketSessionReadsEvents(
        _ method: IPCMethod, enabled: Bool, context: AuthenticatedRequestContext
    ) -> Bool {
        guard enabled, case .events = method else { return false }
        guard let peer = context.peer else { return true }
        return peer.evidence.effectiveUserID == ServiceMethodAuthorization.ownerUserID
    }

    /// One `events` long poll: the wait is capped (`EventsParams.maxWaitMs`)
    /// and runs off the actor, so a poll holds neither the actor nor a hook.
    nonisolated func liveEvents(
        _ params: EventsParams,
        context: AuthenticatedRequestContext,
        sameUIDSocket: Bool
    ) async -> EventsReply {
        await pendingEventsForwarded?.value
        let view = LiveEventView(
            readsPending: Self.sameUIDSocketSession(.pendingList, enabled: sameUIDSocket)
                || ServiceMethodAuthorization.permits(.pendingList, context: context))
        let waitMs = min(max(params.waitMs ?? 0, 0), EventsParams.maxWaitMs)
        return await events.next(
            after: params.after, stream: params.stream, wait: .milliseconds(waitMs), wire: true,
            visible: view.visible)
    }
}

/// What one `events` caller may see: never more than `pendingList` would
/// show it. A caller that may read pending approvals (a same-user socket
/// session, or an XPC peer with the `controlRead` role) sees every event.
/// Any other owner peer sees decisions only, without the host's session
/// id: asks, resolutions and kinds this rvd does not know are left out
/// (their sequence still moves the cursor).
struct LiveEventView: Sendable, Equatable {
    let readsPending: Bool

    func visible(_ event: LiveEvent) -> LiveEvent? {
        if readsPending { return event }
        guard case .decision(var decision) = event.payload else { return nil }
        decision.session = nil
        var shown = event
        shown.payload = .decision(decision)
        return shown
    }
}
