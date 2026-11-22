import Foundation
import RVIPC

/// What one `events` poll found.
public enum LiveEventsPoll: Sendable, Equatable {
    case events(EventsReply)
    /// The rvd answering predates `events` (or refuses the method by name):
    /// not a failure. Keep using what worked before (`pendingWatch`), and
    /// ask again after rvd restarts.
    case unsupported
}

extension ServiceClient {
    /// Headroom past the poll's own wait for the transport timeout.
    static let liveEventsReplyMarginMs = 3_000

    /// One `events` long poll (`sdk/WIRE.md` §4.7). Pass the reply's
    /// `stream` and `cursor` back on the next call. An answer that comes
    /// at once with no events means rvd is at its waiter cap: back off.
    public func liveEvents(_ params: EventsParams) async -> Result<LiveEventsPoll, ServiceCommandError> {
        guard let transport else { return .failure(.noTransport) }
        let waitMs = min(max(params.waitMs ?? 0, 0), EventsParams.maxWaitMs)
        do {
            let reply = try await send(
                EventsCall(params: params), using: transport,
                timeoutMs: waitMs + Self.liveEventsReplyMarginMs,
                undecodableIsServiceError: true)
            return .success(.events(reply))
        } catch IPCCallError.service(let error) where EventsCall.isUnsupported(.error(error)) {
            return .success(.unsupported)
        } catch let error as IPCCallError {
            return .failure(mapCallError(error))
        } catch {
            return .failure(.transport(String(describing: error)))
        }
    }
}
