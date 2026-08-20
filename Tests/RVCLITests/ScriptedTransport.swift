import Foundation
@testable import RVCLI

final class ScriptedTransport: ServiceTransport, @unchecked Sendable {
    let ack: HelloAckView
    let sendError: ServiceTransportError?
    let sendReply: Data?
    nonisolated(unsafe) private var sends = 0

    init(
        ack: HelloAckView,
        sendError: ServiceTransportError? = nil,
        sendReply: Data? = nil
    ) {
        self.ack = ack
        self.sendError = sendError
        self.sendReply = sendReply
    }

    var sendCount: Int { sends }

    func hello(clientSemver: String) async throws -> HelloAckView {
        ack
    }

    func send(_ body: Data) async throws -> Data {
        sends += 1
        if let sendError {
            throw sendError
        }
        return sendReply ?? Data()
    }
}
