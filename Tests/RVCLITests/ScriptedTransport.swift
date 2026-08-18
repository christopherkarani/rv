import Foundation
@testable import RVCLI

final class ScriptedTransport: ServiceTransport, @unchecked Sendable {
    let ack: HelloAckView
    let sendError: ServiceTransportError?
    nonisolated(unsafe) private var sends = 0

    init(ack: HelloAckView, sendError: ServiceTransportError? = nil) {
        self.ack = ack
        self.sendError = sendError
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
        return Data()
    }
}
