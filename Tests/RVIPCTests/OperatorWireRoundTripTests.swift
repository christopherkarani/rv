import Foundation
import Testing
import RVIPC

/// Wire DTOs and the UI bridge request/response envelope round-trip.
/// No service, no XPC: pure Codable stability.
@Suite("Operator wire round trips")
struct OperatorWireRoundTripTests {
    private func item(operationID: UUID = UUID()) -> UIReviewItemDTO {
        UIReviewItemDTO(
            operationID: operationID, kind: "launchCustom", definitionID: nil,
            definitionRevisionDigest: nil, executable: "/bin/echo",
            expectedContentDigest: String(repeating: "a", count: 64),
            workspaceSessionID: UUID(), workingDirectory: "/tmp", arguments: ["hi"],
            io: .pseudoTerminal(rows: 24, columns: 80), environmentPolicy: "sealed",
            intentDigestHex: String(repeating: "c", count: 64), status: "pendingReview",
            advisoryExpiresWall: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func challenge(operationID: UUID = UUID()) -> UIChallengeDTO {
        UIChallengeDTO(
            challengeID: UUID(), operationID: operationID,
            intentDigestHex: String(repeating: "c", count: 64), kind: "launchCustom",
            uiConnectionID: UUID(), issuedWall: Date(timeIntervalSince1970: 1_800_000_000),
            advisoryLifetimeSeconds: 120)
    }

    @Test func bridgeRequestsRoundTrip() throws {
        let id = UUID()
        let completion = UIOperatorCompletion(
            challengeID: UUID(), operationID: id, outcome: .authenticated)
        let cases: [UIBridgeRequest] = [
            .register, .list, .bind(operationID: id), .complete(completion),
            .cancel(operationID: id), .status(operationID: id),
        ]
        for request in cases {
            let decoded = try IPCJSON.decode(UIBridgeRequest.self, from: IPCJSON.encode(request))
            #expect(decoded == request)
        }
    }

    @Test func unknownBridgeRequestFailsClosed() {
        let data = Data("\"nope\"".utf8)
        do {
            _ = try IPCJSON.decode(UIBridgeRequest.self, from: data)
            Issue.record("unknown request must fail decode")
        } catch {}
    }

    @Test func reviewListRoundTrips() throws {
        let list = UIReviewListDTO(items: [item(), item()])
        #expect(try IPCJSON.decode(UIReviewListDTO.self, from: IPCJSON.encode(list)) == list)
    }

    @Test func challengeBundleRoundTrips() throws {
        let id = UUID()
        let bundle = UIChallengeBundleDTO(challenge: challenge(operationID: id),
            item: item(operationID: id))
        #expect(
            try IPCJSON.decode(UIChallengeBundleDTO.self, from: IPCJSON.encode(bundle)) == bundle)
    }

    @Test func registrationAndStatusRoundTrip() throws {
        let registered = UIRegisteredDTO(uiConnection: UUID())
        #expect(
            try IPCJSON.decode(UIRegisteredDTO.self, from: IPCJSON.encode(registered))
                == registered)
        let status = UIOperationStatusDTO(operationID: UUID(), status: "authorized")
        #expect(
            try IPCJSON.decode(UIOperationStatusDTO.self, from: IPCJSON.encode(status)) == status)
    }

    @Test func ioDiscardRoundTrips() throws {
        let decoded = try IPCJSON.decode(UIIODTO.self, from: IPCJSON.encode(UIIODTO.discard))
        #expect(decoded == .discard)
    }

    @Test func unknownIORawValueFailsClosed() {
        do {
            _ = try IPCJSON.decode(UIIODTO.self, from: Data("{\"mystery\":{}}".utf8))
            Issue.record("unknown IO must fail decode")
        } catch {}
    }

    @Test func resultCasesRoundTrip() throws {
        let id = UUID()
        let cases: [IPCResult] = [
            .uiRegistered(UIRegisteredDTO(uiConnection: UUID())),
            .uiReviewList(UIReviewListDTO(items: [item(operationID: id)])),
            .uiChallengeBundle(UIChallengeBundleDTO(
                challenge: challenge(operationID: id), item: item(operationID: id))),
            .uiOperationStatus(UIOperationStatusDTO(operationID: id, status: "failed")),
            .proposeWorkspaceLaunch(ProposeLaunchReply(operationID: id, status: "pendingReview")),
            .launchProposalStatus(ProposalStatusReply(operationID: id, status: "unknown")),
        ]
        for result in cases {
            let response = IPCResponse(id: id, result: result)
            let decoded = try IPCJSON.decode(IPCResponse.self, from: IPCJSON.encode(response))
            #expect(decoded == response)
        }
    }

    @Test func completionCarriesIDsOnlyNeverABearer() throws {
        // The completion names a ceremony; it grants nothing by possession.
        // Pin the exact key set so no token field can slip in silently.
        let completion = UIOperatorCompletion(
            challengeID: UUID(), operationID: UUID(), outcome: .authenticated)
        let data = try IPCJSON.encode(completion)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(Set(json?.keys.map { $0 } ?? []) == ["challengeID", "operationID", "outcome"])
    }

    @Test func outcomeStringsAreStable() {
        #expect(UIAuthenticationOutcome.authenticated.rawValue == "authenticated")
        #expect(UIAuthenticationOutcome.cancelled.rawValue == "cancelled")
        #expect(UIAuthenticationOutcome.unavailable.rawValue == "unavailable")
        #expect(UIAuthenticationOutcome.timedOut.rawValue == "timedOut")
        #expect(UIAuthenticationOutcome.invalidated.rawValue == "invalidated")
        #expect(UIAuthenticationOutcome.failed.rawValue == "failed")
    }
}
