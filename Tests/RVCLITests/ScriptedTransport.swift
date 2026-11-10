import Foundation
import RVIPC
import Synchronization
@testable import RVCLI

final class ScriptedTransport: ServiceTransport {
    let ack: HelloAckView
    let helloError: ServiceTransportError?
    let sendError: ServiceTransportError?
    let sendReply: Data?
    let responseResult: IPCResult?
    let responseID: UUID?
    let responseProtocolName: String?

    /// Replies served in order before `responseResult`.
    private let queuedResults: Mutex<[IPCResult]>
    private let sentBodies = Mutex<[Data]>([])
    private let sendTimeouts = Mutex<[Int]>([])
    private let helloCalls = Mutex(0)
    private let invalidations = Mutex(0)
    private let hookConsults = Mutex(0)

    init(
        ack: HelloAckView,
        helloError: ServiceTransportError? = nil,
        sendError: ServiceTransportError? = nil,
        sendReply: Data? = nil,
        responseResult: IPCResult? = nil,
        responseID: UUID? = nil,
        responseProtocolName: String? = nil,
        responseResults: [IPCResult] = []
    ) {
        self.queuedResults = Mutex(responseResults)
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

    /// Sends that went over the hook-consult session (daemon verified the
    /// way hooks verify it: manifest when installed, else the sibling pin).
    var hookConsultCount: Int { hookConsults.withLock { $0 } }

    func hello(clientSemver: String) async throws -> HelloAckView {
        helloCalls.withLock { $0 += 1 }
        if let helloError {
            throw helloError
        }
        return ack
    }

    func send(_ body: Data) async throws -> Data {
        sentBodies.withLock { $0.append(body) }
        if let sendError {
            throw sendError
        }
        let queued = queuedResults.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        if let responseResult = queued ?? responseResult {
            let request = try IPCJSON.decode(IPCRequest.self, from: body)
            return try IPCJSON.encode(
                IPCResponse(
                    id: responseID ?? request.id,
                    protocolName: responseProtocolName ?? request.protocolName,
                    result: responseResult
                )
            )
        }
        return sendReply ?? Data()
    }

    func send(_ body: Data, timeoutMs: Int) async throws -> Data {
        sendTimeouts.withLock { $0.append(timeoutMs) }
        return try await send(body)
    }

    func sendHookConsult(_ body: Data, timeoutMs: Int) async throws -> Data {
        hookConsults.withLock { $0 += 1 }
        return try await send(body, timeoutMs: timeoutMs)
    }

    func invalidate() {
        invalidations.withLock { $0 += 1 }
    }
}
