import Foundation
import RVDomain
import RVIPC

/// The bytes channel to rvd (XPC on macOS). The app adapts its transport to
/// this; tests fake it.
public protocol GlanceWire: Sendable {
    /// Greets rvd on this channel. True when rvd accepted the hello.
    func hello() async throws -> Bool
    func send(_ body: Data, timeoutMs: Int) async throws -> Data
    /// Drops the connection after a failure; the next call reconnects.
    func invalidate()
}

/// What one `events` poll found.
public enum GlancePoll: Sendable, Equatable {
    case events(EventsReply)
    /// This rvd predates `events`.
    case unsupported
    case down(String)
}

/// The menu bar's only way to talk to rvd. It can ask for three things,
/// live events, the pending list and the loosen proposals waiting, and
/// nothing else: the menu bar reads
/// rv, it never changes it (no resolve, no rule, no mode, no pause).
public struct GlanceReader: Sendable {
    /// The only methods the menu bar ever encodes.
    public enum Read: Sendable, Equatable {
        case events(EventsParams)
        case pendingList
        case proposals

        public var method: IPCMethod {
            switch self {
            case .events(let params): .events(params)
            case .pendingList: .pendingList
            case .proposals: .listProposals(ListProposalsParams())
            }
        }
    }

    /// Headroom past a long poll's own wait.
    static let replyMarginMs = 3_000
    static let unaryTimeoutMs = 2_000

    let wire: any GlanceWire

    public init(wire: any GlanceWire) {
        self.wire = wire
    }

    public func events(_ params: EventsParams) async -> GlancePoll {
        let waitMs = min(max(params.waitMs ?? 0, 0), EventsParams.maxWaitMs)
        switch await call(.events(params), timeoutMs: waitMs + Self.replyMarginMs) {
        case .success(.events(let reply)):
            return .events(reply)
        case .success(let other) where EventsCall.isUnsupported(other):
            return .unsupported
        case .success(let other):
            return .down(Self.describe(other))
        case .failure(let text):
            return .down(text.reason)
        }
    }

    /// Every ask awaiting a human, and the agent that asked.
    public func pendingAsks() async -> Result<[ApprovalID: HookHost], GlanceReadFailure> {
        switch await call(.pendingList, timeoutMs: Self.unaryTimeoutMs) {
        case .success(.pendingList(let reply)):
            return .success(Dictionary(reply.items.map { ($0.id, $0.host) }, uniquingKeysWith: { first, _ in first }))
        case .success(let other):
            return .failure(GlanceReadFailure(Self.describe(other)))
        case .failure(let text):
            return .failure(text)
        }
    }

    /// The loosen proposals waiting for the owner (F2). An rvd that predates
    /// proposals has none.
    public func pendingProposals() async -> Result<Set<ProposalID>, GlanceReadFailure> {
        switch await call(.proposals, timeoutMs: Self.unaryTimeoutMs) {
        case .success(.listProposals(let reply)):
            return .success(Set(reply.proposals.filter { $0.status == .pending }.map(\.id)))
        case .success(.error(.unknownMethod)), .success(.error(.decodeFailed)):
            return .success([])
        case .success(let other):
            return .failure(GlanceReadFailure(Self.describe(other)))
        case .failure(let text):
            return .failure(text)
        }
    }

    /// One request; on `handshakeRequired` it greets rvd and asks once more.
    private func call(_ read: Read, timeoutMs: Int) async -> Result<IPCResult, GlanceReadFailure> {
        let first = await once(read, timeoutMs: timeoutMs)
        guard case .success(.error(.protocolSkew(.handshakeRequired))) = first else { return first }
        do {
            guard try await wire.hello() else {
                wire.invalidate()
                return .failure(GlanceReadFailure("rvd refused the hello"))
            }
        } catch {
            wire.invalidate()
            return .failure(GlanceReadFailure("rvd did not answer the hello"))
        }
        return await once(read, timeoutMs: timeoutMs)
    }

    private func once(_ read: Read, timeoutMs: Int) async -> Result<IPCResult, GlanceReadFailure> {
        let request = IPCRequest(method: read.method)
        do {
            let body = try IPCJSON.encode(request)
            let data = try await wire.send(body, timeoutMs: timeoutMs)
            let response = try IPCJSON.decode(IPCResponse.self, from: data)
            // rvd answers an ungreeted or undecodable request without
            // echoing its id (as `ServiceClient.send` accepts too).
            if response.protocolName == request.protocolName, case .error(let error) = response.result,
               error == .decodeFailed || error == .unknownMethod || error == .protocolSkew(.handshakeRequired)
            {
                return .success(response.result)
            }
            guard response.id == request.id, response.protocolName == request.protocolName else {
                wire.invalidate()
                return .failure(GlanceReadFailure("rvd answered a different request"))
            }
            return .success(response.result)
        } catch {
            wire.invalidate()
            return .failure(GlanceReadFailure("rvd isn't answering"))
        }
    }

    private static func describe(_ result: IPCResult) -> String {
        if case .error(let error) = result { return "rvd refused the read (\(error))" }
        return "rvd sent an unexpected reply"
    }
}

public struct GlanceReadFailure: Error, Sendable, Equatable {
    public var reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}
