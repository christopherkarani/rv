import Foundation
import Testing
import RVDomain
import RVIPC

/// K2 unlock-review wire: every request and reply round-trips, and a frame
/// that is ambiguous or names an answer rvd does not know fails decode.
struct UnlockReviewWireTests {
    private let hash = String(repeating: "ab", count: 32)

    private func item() -> UIUnlockItemDTO {
        UIUnlockItemDTO(
            codeHash: hash, code: "a7c835", checkWords: ["orchid", "rocket", "crane"], host: .claude,
            command: "git push --force origin main", workingDirectory: "/tmp/ws", rule: "core.git:push-force",
            agentSays: "Force-push my branch", promptText: "allow once \"git push --force origin main\" in /tmp/ws",
            status: .waiting, advisoryExpiresWall: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func requestsRoundTrip() throws {
        let cases: [UIUnlockBridgeRequest] = [
            .unlockList,
            .unlockBind(codeHash: hash),
            .unlockComplete(UIUnlockCompletion(
                challengeID: UUID(), codeHash: hash, decision: .alwaysAllow, outcome: .authenticated)),
            .unlockRelease(codeHash: hash),
        ]
        for request in cases {
            #expect(try IPCJSON.decode(UIUnlockBridgeRequest.self, from: IPCJSON.encode(request)) == request)
        }
    }

    @Test func repliesRoundTripInTheIPCEnvelope() throws {
        let bundle = UIUnlockChallengeBundleDTO(
            challenge: UIUnlockChallengeDTO(
                challengeID: UUID(), codeHash: hash, uiConnectionID: UUID(),
                issuedWall: Date(timeIntervalSince1970: 1_800_000_000), advisoryLifetimeSeconds: 300),
            item: item())
        let results: [IPCResult] = [
            .uiUnlockList(UIUnlockListDTO(items: [item()])),
            .uiUnlockChallengeBundle(bundle),
            .uiUnlockStatus(UIUnlockStatusDTO(codeHash: hash, status: .alwaysAllowed)),
        ]
        for result in results {
            let response = IPCResponse(id: UUID(), result: result)
            #expect(try IPCJSON.decode(IPCResponse.self, from: IPCJSON.encode(response)) == response)
        }
        #expect(item().approvable)
    }

    @Test func aFrameNamingTwoRequestsOrAnUnknownAnswerFailsDecode() {
        let two = Data(#"{"unlockList":{},"unlockRelease":"\#(hash)"}"#.utf8)
        #expect(throws: (any Error).self) { try IPCJSON.decode(UIUnlockBridgeRequest.self, from: two) }
        let loosen = Data(#"""
            {"unlockComplete":{"challengeID":"\#(UUID().uuidString)","codeHash":"\#(hash)",\#
            "decision":"loosenRule","outcome":"authenticated"}}
            """#.utf8)
        #expect(throws: (any Error).self) { try IPCJSON.decode(UIUnlockBridgeRequest.self, from: loosen) }
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(UIUnlockBridgeRequest.self, from: Data(#"{"unlockApproveEverything":{}}"#.utf8))
        }
    }

    @Test func theDecisionsAreExactlyOnceAndAlways() {
        #expect(UIUnlockDecision.allCases == [.allowOnce, .alwaysAllow])
        #expect(UIBridgeWire.unlockRequestKey == "rv.ui-unlock-request")
    }
}
