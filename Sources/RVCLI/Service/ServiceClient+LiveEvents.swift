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
    ///
    /// Polls go over `eventsTransport`, a connection of their own, so a
    /// poll parked in rvd never delays this client's other requests. A
    /// connection rvd has not greeted yet (new, or reconnected after an
    /// error) answers `handshakeRequired`: the poll says hello on it and
    /// asks once more.
    public func liveEvents(_ params: EventsParams) async -> Result<LiveEventsPoll, ServiceCommandError> {
        switch await exchange(params) {
        case .polled(let result):
            return outcome(result)
        case .noTransport:
            return .failure(.noTransport)
        case .helloRefused:
            return .failure(.service("helloRefused"))
        case .helloFailed(let text):
            return .failure(.transport(text))
        }
    }

    /// A live feed over this client's events channel (`LiveEventFeed`):
    /// the cursor, reconnects, skew and cancellation handled.
    public func liveFeed(
        start: LiveFeedStart = .now, pacing: LiveFeedPacing = LiveFeedPacing()
    ) -> LiveEventFeed<ServiceClient> {
        LiveEventFeed(source: self, start: start, pacing: pacing)
    }

    private enum Exchange {
        case polled(Result<EventsReply, PollFailure>)
        case noTransport
        case helloRefused
        case helloFailed(String)
    }

    /// A cancelled poll stops at its next step: it sends nothing more, and
    /// never invalidates `eventsTransport`, which a newer feed on this
    /// client may already be using.
    private func exchange(_ params: EventsParams) async -> Exchange {
        guard let transport = eventsTransport else { return .noTransport }
        if Task.isCancelled { return .polled(.failure(.cancelled)) }
        let first = await pollOnce(params, using: transport)
        guard case .failure(.service(.protocolSkew(.handshakeRequired))) = first else {
            return .polled(first)
        }
        if Task.isCancelled { return .polled(.failure(.cancelled)) }
        do {
            let ack = try await transport.hello(clientSemver: ProtocolVersion.serviceSemver)
            if Task.isCancelled { return .polled(.failure(.cancelled)) }
            guard ack.status == .ok else {
                transport.invalidate()
                return .helloRefused
            }
        } catch {
            if Task.isCancelled { return .polled(.failure(.cancelled)) }
            transport.invalidate()
            return .helloFailed(String(describing: error))
        }
        if Task.isCancelled { return .polled(.failure(.cancelled)) }
        return .polled(await pollOnce(params, using: transport))
    }

    private func pollOnce(
        _ params: EventsParams, using transport: any ServiceTransport
    ) async -> Result<EventsReply, PollFailure> {
        let waitMs = min(max(params.waitMs ?? 0, 0), EventsParams.maxWaitMs)
        do {
            return .success(try await send(
                EventsCall(params: params), using: transport,
                timeoutMs: waitMs + Self.liveEventsReplyMarginMs,
                undecodableIsServiceError: true))
        } catch let error as IPCCallError {
            if case .service(let service) = error { return .failure(.service(service)) }
            return .failure(.call(error))
        } catch {
            return .failure(.transport(String(describing: error)))
        }
    }

    private enum PollFailure: Error {
        case service(IPCError)
        case call(IPCCallError)
        case transport(String)
        /// The poll's task was cancelled before it finished.
        case cancelled
    }

    private func outcome(_ result: Result<EventsReply, PollFailure>) -> Result<LiveEventsPoll, ServiceCommandError> {
        switch result {
        case .success(let reply):
            return .success(.events(reply))
        case .failure(.service(let error)) where EventsCall.isUnsupported(.error(error)):
            return .success(.unsupported)
        case .failure(.service(let error)):
            return .failure(.service(String(describing: error)))
        case .failure(.call(let error)):
            return .failure(mapCallError(error))
        case .failure(.transport(let text)):
            return .failure(.transport(text))
        case .failure(.cancelled):
            return .failure(.transport("cancelled"))
        }
    }
}

extension ServiceClient: LiveEventsPolling {
    /// One poll, as `LiveEventFeed` reads it: an old rvd is `unsupported`,
    /// a refused hello or a skewed frame is `skewed`, a non-owner is
    /// `refused`, and anything else that is not a reply is `failed`.
    public func pollLiveEvents(_ params: EventsParams) async -> LiveEventsPollResult {
        switch await exchange(params) {
        case .polled(.success(let reply)):
            return .reply(reply)
        case .polled(.failure(.service(let error))):
            if EventsCall.isUnsupported(.error(error)) { return .unsupported }
            switch error {
            case .protocolSkew: return .skewed
            case .authorizationDenied: return .refused
            default: return .failed(String(describing: error))
            }
        case .polled(.failure(.call(let error))):
            if case .transport(let text) = mapCallError(error) { return .failed(text) }
            return .failed(String(describing: error))
        case .polled(.failure(.transport(let text))), .helloFailed(let text):
            return .failed(text)
        case .polled(.failure(.cancelled)):
            return .failed("cancelled")
        case .helloRefused:
            return .skewed
        case .noTransport:
            return .failed("noTransport")
        }
    }
}
