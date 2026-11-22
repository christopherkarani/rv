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
        guard let transport = eventsTransport else { return .failure(.noTransport) }
        let first = await pollOnce(params, using: transport)
        guard case .failure(.service(.protocolSkew(.handshakeRequired))) = first else {
            return outcome(first)
        }
        do {
            let ack = try await transport.hello(clientSemver: ProtocolVersion.serviceSemver)
            guard ack.status == .ok else {
                transport.invalidate()
                return .failure(.service("helloRefused"))
            }
        } catch {
            transport.invalidate()
            return .failure(.transport(String(describing: error)))
        }
        return outcome(await pollOnce(params, using: transport))
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
        }
    }
}
