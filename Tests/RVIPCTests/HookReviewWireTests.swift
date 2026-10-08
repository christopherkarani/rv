import Foundation
import Testing
import RVDomain
import RVIPC

struct HookReviewWireTests {
    private func reviewItem(allowOnceAvailable: Bool? = nil) -> UIHookReviewItemDTO {
        UIHookReviewItemDTO(
            approvalID: "hook-1", host: "pi", session: "sess-pi",
            actionKind: "shell", exactCommand: "git reset --hard",
            workingDirectory: "/tmp/ws", policyReason: "hostAsk",
            actionFingerprint: "pi:sess-pi:/tmp/ws:git reset --hard",
            status: .awaitingHuman,
            advisoryExpiresWall: Date(timeIntervalSince1970: 1_800_000_000),
            allowOnceAvailable: allowOnceAvailable)
    }

    private func challenge() -> UIHookChallengeDTO {
        UIHookChallengeDTO(
            challengeID: UUID(), approvalID: "hook-1",
            actionFingerprint: "pi:sess-pi:/tmp/ws:git reset --hard",
            uiConnectionID: UUID(),
            issuedWall: Date(timeIntervalSince1970: 1_800_000_000),
            advisoryLifetimeSeconds: 300)
    }

    @Test func hookBridgeRequestsRoundTrip() throws {
        let cases: [UIHookBridgeRequest] = [
            .hookList,
            .hookBind(approvalID: "hook-1"),
            .hookComplete(UIHookCompletion(
                challengeID: UUID(), approvalID: "hook-1", outcome: .authenticated)),
            .hookDeny(UIHookDeny(challengeID: UUID(), approvalID: "hook-1")),
            .hookCancel(approvalID: "hook-1"),
            .hookStatus(approvalID: "hook-1"),
        ]
        for request in cases {
            let decoded = try IPCJSON.decode(
                UIHookBridgeRequest.self, from: IPCJSON.encode(request))
            #expect(decoded == request)
        }
    }

    @Test func hookDTOsRoundTrip() throws {
        let item = reviewItem()
        #expect(try IPCJSON.decode(
            UIHookReviewItemDTO.self, from: IPCJSON.encode(item)) == item)
        let list = UIHookReviewListDTO(items: [item])
        #expect(try IPCJSON.decode(
            UIHookReviewListDTO.self, from: IPCJSON.encode(list)) == list)
        let bundle = UIHookChallengeBundleDTO(challenge: challenge(), item: item)
        #expect(try IPCJSON.decode(
            UIHookChallengeBundleDTO.self, from: IPCJSON.encode(bundle)) == bundle)
        let status = UIHookStatusDTO(approvalID: "hook-1", status: .allowedOnce)
        #expect(try IPCJSON.decode(
            UIHookStatusDTO.self, from: IPCJSON.encode(status)) == status)
        let deny = UIHookDeny(challengeID: UUID(), approvalID: "hook-1")
        #expect(try IPCJSON.decode(
            UIHookDeny.self, from: IPCJSON.encode(deny)) == deny)
        let completion = UIHookCompletion(
            challengeID: UUID(), approvalID: "hook-1", outcome: .cancelled)
        #expect(try IPCJSON.decode(
            UIHookCompletion.self, from: IPCJSON.encode(completion)) == completion)
    }

    @Test func hookIPCResultsRoundTrip() throws {
        let results: [IPCResult] = [
            .uiHookReviewList(UIHookReviewListDTO(items: [reviewItem()])),
            .uiHookChallengeBundle(UIHookChallengeBundleDTO(
                challenge: challenge(), item: reviewItem())),
            .uiHookStatus(UIHookStatusDTO(approvalID: "hook-1", status: .denied)),
        ]
        for result in results {
            let response = IPCResponse(id: UUID(), result: result)
            let decoded = try IPCJSON.decode(IPCResponse.self, from: IPCJSON.encode(response))
            #expect(decoded == response)
        }
    }

    @Test func hookAndActionRequestsDoNotConfuse() throws {
        // Hook bytes must not decode as an action request.
        let hookBytes = try IPCJSON.encode(
            UIHookBridgeRequest.hookComplete(UIHookCompletion(
                challengeID: UUID(), approvalID: "hook-1", outcome: .authenticated)))
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(UIActionBridgeRequest.self, from: hookBytes)
        }
        // Action bytes must not decode as a hook request.
        let actionBytes = try IPCJSON.encode(
            UIActionBridgeRequest.actionComplete(UIActionCompletion(
                challengeID: UUID(), approvalID: UUID(), outcome: .authenticated)))
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(UIHookBridgeRequest.self, from: actionBytes)
        }
        // Hook bytes must not decode as a launch request.
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(UIBridgeRequest.self, from: hookBytes)
        }
        // A hook completion is not an action completion, structurally.
        let hookCompletion = UIHookCompletion(
            challengeID: UUID(), approvalID: "hook-1", outcome: .authenticated)
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(
                UIActionCompletion.self, from: IPCJSON.encode(hookCompletion))
        }
    }

    @Test func unknownHookRequestFailsClosed() throws {
        let garbage = Data(#"{"nope":1}"#.utf8)
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(UIHookBridgeRequest.self, from: garbage)
        }
    }

    @Test func reviewItemAvailabilityFlagRoundTrips() throws {
        // Nil encodes without the key — the older-server shape — and
        // decodes back to nil, so new UIs tolerate stale daemons.
        for flag in [true, false, nil] {
            let item = reviewItem(allowOnceAvailable: flag)
            #expect(
                try IPCJSON.decode(
                    UIHookReviewItemDTO.self, from: IPCJSON.encode(item)) == item)
        }
    }
}
