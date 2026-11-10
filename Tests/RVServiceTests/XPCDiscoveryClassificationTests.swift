#if canImport(XPC)
import Foundation
import Testing
@testable import RVService
@preconcurrency import XPC

/// Only a discovery Hello that launchd refuses before this client ever heard
/// from rvd proves rvd absent; everything else may have reached it.
struct XPCDiscoveryClassificationTests {
    @Test func unregisteredServiceIsConnectFailed() async {
        let client = XPCEvaluateClient(serviceName: "dev.rv.evaluate.unregistered-test")
        defer { client.invalidate() }
        await #expect(throws: XPCEvaluateClientError.connectFailed) {
            try await client.perform(Data())
        }
    }

    @Test func onlyInvalidDropsTheCachedConnection() {
        #expect(XPCEvaluateClient.dropsCachedConnection(on: XPC_ERROR_CONNECTION_INVALID))
        // Cancelling on INTERRUPTED would turn pending replies into INVALID,
        // which reads as "never registered" for an rvd that died mid-request.
        #expect(!XPCEvaluateClient.dropsCachedConnection(on: XPC_ERROR_CONNECTION_INTERRUPTED))
    }

    @Test func invalidIsAbsenceOnlyOnDiscoveryWhileProvable() {
        let invalid = XPC_ERROR_CONNECTION_INVALID
        let interrupted = XPC_ERROR_CONNECTION_INTERRUPTED
        #expect(XPCEvaluateClient.replyFailure(invalid, discovery: true, absenceProvable: true) == .connectFailed)
        #expect(XPCEvaluateClient.replyFailure(invalid, discovery: true, absenceProvable: false) == .connectionLost)
        #expect(XPCEvaluateClient.replyFailure(invalid, discovery: false, absenceProvable: true) == .connectionLost)
        #expect(XPCEvaluateClient.replyFailure(interrupted, discovery: true, absenceProvable: true) == .connectionLost)
    }
}
#endif
