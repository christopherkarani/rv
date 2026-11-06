import Foundation
import RVIPC
import Synchronization
@testable import RVCLI

final class ScriptedTransport: ServiceTransport {
    let ack: HelloAckView
    let helloError: ServiceTransportFailure?
    let sendError: ServiceTransportFailure?
    let sendReply: Data?
    let responseResult: IPCResult?
    let responseID: UUID?
    let responseProtocolName: String?

    private let sentBodies = Mutex<[Data]>([])
    private let sendTimeouts = Mutex<[Int]>([])
    private let helloCalls = Mutex(0)
    private let invalidations = Mutex(0)

    init(
        ack: HelloAckView,
        helloError: ServiceTransportFailure? = nil,
        sendError: ServiceTransportFailure? = nil,
        sendReply: Data? = nil,
        responseResult: IPCResult? = nil,
        responseID: UUID? = nil,
        responseProtocolName: String? = nil
    ) {
        self.ack = ack
        self.helloError = helloError
        self.sendError = sendError
        self.sendReply = sendReply
        self.responseResult = responseResult
        self.responseID = responseID
        self.responseProtocolName = responseProtocolName
    }

    var sendCount: Int { sentBodies.withLock(\.count) }

    var sends: [Data] { sentBodies.withLock { $0 } }

    var helloCount: Int { helloCalls.withLock { $0 } }

    var lastSendTimeoutMs: Int? { sendTimeouts.withLock(\.last) }

    var invalidationCount: Int { invalidations.withLock { $0 } }

    func hello(clientSemver: String) async throws(ServiceTransportFailure) -> HelloAckView {
        helloCalls.withLock { $0 += 1 }
        if let helloError {
            throw helloError
        }
        return ack
    }

    func send(_ body: Data) async throws(ServiceTransportFailure) -> Data {
        sentBodies.withLock { $0.append(body) }
        if let sendError {
            throw sendError
        }
        if let responseResult {
            do {
                let request = try IPCJSON.decode(IPCRequest.self, from: body)
                return try IPCJSON.encode(
                    IPCResponse(
                        id: responseID ?? request.id,
                        protocolName: responseProtocolName ?? request.protocolName,
                        result: responseResult
                    )
                )
            } catch {
                throw .malformedReply
            }
        }
        return sendReply ?? Data()
    }

    func send(_ body: Data, timeoutMs: Int) async throws(ServiceTransportFailure) -> Data {
        sendTimeouts.withLock { $0.append(timeoutMs) }
        return try await send(body)
    }

    func invalidate() {
        invalidations.withLock { $0 += 1 }
    }
}
