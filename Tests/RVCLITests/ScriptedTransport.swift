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

    private let sentBodies = Mutex<[Data]>([])
    private let sendTimeouts = Mutex<[Int]>([])
    private let helloCalls = Mutex(0)
    private let invalidations = Mutex(0)

    init(
        ack: HelloAckView,
        helloError: ServiceTransportError? = nil,
        sendError: ServiceTransportError? = nil,
        sendReply: Data? = nil,
        responseResult: IPCResult? = nil
    ) {
        self.ack = ack
        self.helloError = helloError
        self.sendError = sendError
        self.sendReply = sendReply
        self.responseResult = responseResult
    }

    var sendCount: Int { sentBodies.withLock(\.count) }

    var sends: [Data] { sentBodies.withLock { $0 } }

    var helloCount: Int { helloCalls.withLock { $0 } }

    var lastSendTimeoutMs: Int? { sendTimeouts.withLock(\.last) }

    var invalidationCount: Int { invalidations.withLock { $0 } }

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
        if let responseResult {
            let request = try IPCJSON.decode(IPCRequest.self, from: body)
            return try IPCJSON.encode(IPCResponse(id: request.id, result: responseResult))
        }
        return sendReply ?? Data()
    }

    func send(_ body: Data, timeoutMs: Int) async throws -> Data {
        sendTimeouts.withLock { $0.append(timeoutMs) }
        return try await send(body)
    }

    func invalidate() {
        invalidations.withLock { $0 += 1 }
    }
}
