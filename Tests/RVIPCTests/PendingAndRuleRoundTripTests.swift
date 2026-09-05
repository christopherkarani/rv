import Foundation
import Testing
import RVDomain
@testable import RVIPC

struct PendingAndRuleRoundTripTests {
    private let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    private var identity: ApprovalIdentity {
        ApprovalIdentity(
            session: SessionIdentity(rawValue: "sess"),
            agent: AgentIdentity(rawValue: "pi")
        )
    }

    private var listItem: PendingListItem {
        PendingListItem(
            id: ApprovalID(rawValue: "ask-1"),
            host: .pi,
            folder: "ws",
            actionKind: "git push",
            fingerprint: ActionFingerprint(rawValue: "shell:git"),
            sessionSuffix: "ab12",
            identity: identity
        )
    }

    @Test func pendingListRequestFrame_bytesMatchGolden() throws {
        let request = IPCRequest(id: id, method: .pendingList)
        let data = try IPCJSON.encode(request)
        let golden =
            #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"pendingList":{}},"protocol":"rv.ipc.v1"}"#
        #expect(String(data: data, encoding: .utf8) == golden)
        #expect(try IPCJSON.decode(IPCRequest.self, from: data) == request)
    }

    @Test func pendingListReplyFrame_bytesMatchGoldenAndOmitsCommand() throws {
        let reply = PendingListReply(generation: 3, items: [listItem])
        let response = IPCResponse(id: id, result: .pendingList(reply))
        let data = try IPCJSON.encode(response)
        let golden =
            #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"pendingList":{"generation":3,"items":[{"actionKind":"git push","fingerprint":"shell:git","folder":"ws","host":"pi","id":"ask-1","identity":{"agent":"pi","session":"sess"},"sessionSuffix":"ab12"}]}}}"#
        #expect(String(data: data, encoding: .utf8) == golden)
        #expect(try IPCJSON.decode(IPCResponse.self, from: data) == response)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["protocol"] as? String == ProtocolVersion.name)
        #expect(ProtocolVersion.name == "rv.ipc.v1")
        let result = try #require(object["result"] as? [String: Any])
        let body = try #require(result["pendingList"] as? [String: Any])
        let items = try #require(body["items"] as? [[String: Any]])
        let item = try #require(items.first)
        #expect(item["command"] == nil)
        #expect(item["supportingCommand"] == nil)
        #expect(item["createdAt"] == nil)
        #expect(item["now"] == nil)
        #expect(String(data: data, encoding: .utf8)?.contains("isDenied") == false)
        #expect(String(data: data, encoding: .utf8)?.contains("\"command\"") == false)
    }

    @Test func pendingListItem_omittedSessionSuffixStaysOffTheWire() throws {
        let item = PendingListItem(
            id: ApprovalID(rawValue: "ask-1"),
            host: .grok,
            folder: "ws",
            actionKind: "shell",
            fingerprint: ActionFingerprint(rawValue: "shell:git"),
            sessionSuffix: nil,
            identity: identity
        )
        let data = try IPCJSON.encode(item)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["sessionSuffix"] == nil)
        #expect(object["command"] == nil)
        #expect(object["createdAt"] == nil)
        #expect(try IPCJSON.decode(PendingListItem.self, from: data) == item)
    }

    @Test func pendingWatchRequestFrame_bytesMatchGolden() throws {
        let request = IPCRequest(id: id, method: .pendingWatch(PendingWatchParams(afterGeneration: 7)))
        let data = try IPCJSON.encode(request)
        let golden =
            #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"pendingWatch":{"afterGeneration":7}},"protocol":"rv.ipc.v1"}"#
        #expect(String(data: data, encoding: .utf8) == golden)
        #expect(try IPCJSON.decode(IPCRequest.self, from: data) == request)
    }

    @Test func pendingWatchUnchangedPoll_sameGenerationEmptyItems() throws {
        let reply = PendingWatchReply(generation: 7, items: [])
        let response = IPCResponse(id: id, result: .pendingWatch(reply))
        let data = try IPCJSON.encode(response)
        let golden =
            #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"pendingWatch":{"generation":7,"items":[]}}}"#
        #expect(String(data: data, encoding: .utf8) == golden)
        #expect(try IPCJSON.decode(IPCResponse.self, from: data) == response)
        guard case .pendingWatch(let decoded) = try IPCJSON.decode(IPCResponse.self, from: data).result else {
            Issue.record("unchanged poll must decode as pendingWatch")
            return
        }
        #expect(decoded.generation == 7)
        #expect(decoded.items.isEmpty)
    }

    @Test func pendingResolveRequestFrame_bytesMatchGolden() throws {
        let params = PendingResolveParams(
            id: ApprovalID(rawValue: "ask-1"),
            decision: .allowOnce,
            fingerprint: ActionFingerprint(rawValue: "shell:git"),
            identity: identity
        )
        let request = IPCRequest(id: id, method: .pendingResolve(params))
        let data = try IPCJSON.encode(request)
        let golden =
            #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"pendingResolve":{"decision":"allowOnce","fingerprint":"shell:git","id":"ask-1","identity":{"agent":"pi","session":"sess"}}},"protocol":"rv.ipc.v1"}"#
        #expect(String(data: data, encoding: .utf8) == golden)
        #expect(try IPCJSON.decode(IPCRequest.self, from: data) == request)
    }

    @Test func pendingResolveReplyFrame_omitsSupportingCommand() throws {
        let reply = PendingResolveReply(id: ApprovalID(rawValue: "ask-1"), terminal: true)
        let response = IPCResponse(id: id, result: .pendingResolve(reply))
        let data = try IPCJSON.encode(response)
        let golden =
            #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"pendingResolve":{"id":"ask-1","terminal":true}}}"#
        #expect(String(data: data, encoding: .utf8) == golden)
        #expect(try IPCJSON.decode(IPCResponse.self, from: data) == response)
        #expect(String(data: data, encoding: .utf8)?.contains("supportingCommand") == false)
        #expect(String(data: data, encoding: .utf8)?.contains("\"command\"") == false)
    }

    @Test(arguments: ["createRule", "alwaysAllow", "", "maybe"])
    func pendingResolve_rejectsInvalidDecision(_ decision: String) throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "protocol": ProtocolVersion.name,
            "method": [
                "pendingResolve": [
                    "id": "ask-1",
                    "decision": decision,
                    "fingerprint": "shell:git",
                    "identity": ["session": "sess", "agent": "pi"],
                ]
            ],
        ])
        do {
            _ = try IPCJSON.decode(IPCRequest.self, from: payload)
            Issue.record("pendingResolve decision \(decision) must fail decode")
        } catch let error as DecodingError {
            guard case .dataCorrupted = error else {
                Issue.record("expected dataCorrupted, got \(error)")
                return
            }
        }
    }

    @Test func pendingResolve_missingDecisionFailsDecode() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "protocol": ProtocolVersion.name,
            "method": [
                "pendingResolve": [
                    "id": "ask-1",
                    "fingerprint": "shell:git",
                    "identity": ["session": "sess", "agent": "pi"],
                ]
            ],
        ])
        #expect(throws: DecodingError.self) {
            try IPCJSON.decode(IPCRequest.self, from: payload)
        }
    }

    @Test func rulePreviewRequestAndReply_roundTrip() throws {
        let params = RulePreviewParams(id: ApprovalID(rawValue: "ask-1"), polarity: .allow)
        let request = IPCRequest(id: id, method: .rulePreview(params))
        let requestData = try IPCJSON.encode(request)
        let requestGolden =
            #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"rulePreview":{"id":"ask-1","polarity":"allow"}},"protocol":"rv.ipc.v1"}"#
        #expect(String(data: requestData, encoding: .utf8) == requestGolden)
        #expect(try IPCJSON.decode(IPCRequest.self, from: requestData) == request)
        let requestObject = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let method = try #require(requestObject["method"] as? [String: Any])
        let previewParams = try #require(method["rulePreview"] as? [String: Any])
        #expect(previewParams["draft"] == nil)
        #expect(previewParams["command"] == nil)
        #expect(previewParams["supportingCommand"] == nil)

        let typedAllowDraft =
            #"{"polarity":"allow","predicate":{"gitPush":{"branch":"feature","force":"force"}},"v":2}"#
        let reply = RulePreviewReply(
            sentence: "Always allow force-push to feature. Future matches in this scope will not wait.",
            draft: typedAllowDraft,
            allowedToSave: true
        )
        let response = IPCResponse(id: id, result: .rulePreview(reply))
        let responseData = try IPCJSON.encode(response)
        let responseGolden =
            #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"rulePreview":{"allowedToSave":true,"draft":"{\"polarity\":\"allow\",\"predicate\":{\"gitPush\":{\"branch\":\"feature\",\"force\":\"force\"}},\"v\":2}","sentence":"Always allow force-push to feature. Future matches in this scope will not wait."}}}"#
        #expect(String(data: responseData, encoding: .utf8) == responseGolden)
        let decoded = try IPCJSON.decode(IPCResponse.self, from: responseData)
        #expect(decoded == response)
        guard case .rulePreview(let decodedReply) = decoded.result else {
            Issue.record("rulePreview reply must decode as rulePreview")
            return
        }
        try assertTypedGitPushDraft(decodedReply.draft, polarity: "allow", branch: "feature")
        #expect(decodedReply.allowedToSave == true)
        try assertRulePreviewWireOmitsCommand(responseData)
    }

    @Test func rulePreviewReply_hardStopAllowedToSaveFalse_roundTrip() throws {
        let typedAllowDraft =
            #"{"polarity":"allow","predicate":{"gitPush":{"branch":"main","force":"force"}},"v":2}"#
        let reply = RulePreviewReply(
            sentence:
                "This action mutates a protected shared branch. Always-allow cannot override that hard stop.",
            draft: typedAllowDraft,
            allowedToSave: false
        )
        let response = IPCResponse(id: id, result: .rulePreview(reply))
        let responseData = try IPCJSON.encode(response)
        let responseGolden =
            #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"rulePreview":{"allowedToSave":false,"draft":"{\"polarity\":\"allow\",\"predicate\":{\"gitPush\":{\"branch\":\"main\",\"force\":\"force\"}},\"v\":2}","sentence":"This action mutates a protected shared branch. Always-allow cannot override that hard stop."}}}"#
        #expect(String(data: responseData, encoding: .utf8) == responseGolden)
        let decoded = try IPCJSON.decode(IPCResponse.self, from: responseData)
        #expect(decoded == response)
        guard case .rulePreview(let decodedReply) = decoded.result else {
            Issue.record("hard-stop rulePreview must decode as rulePreview")
            return
        }
        #expect(decodedReply.allowedToSave == false)
        try assertTypedGitPushDraft(decodedReply.draft, polarity: "allow", branch: "main")
        try assertRulePreviewWireOmitsCommand(responseData)
        let object = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let body = try #require(result["rulePreview"] as? [String: Any])
        #expect(body["allowedToSave"] as? Bool == false)
    }

    @Test(arguments: ["deny", "allowOnce", "", "Always"])
    func rulePolarity_rejectsUnknownStrings(_ raw: String) throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": "ask-1",
            "polarity": raw,
        ])
        do {
            _ = try IPCJSON.decode(RulePreviewParams.self, from: payload)
            Issue.record("RulePolarity \(raw) must fail decode")
        } catch let error as DecodingError {
            guard case .dataCorrupted = error else {
                Issue.record("expected dataCorrupted, got \(error)")
                return
            }
        }
    }

    @Test func ruleSaveRequestAndReply_roundTrip() throws {
        let params = RuleSaveParams(
            id: ApprovalID(rawValue: "ask-1"),
            polarity: .block,
            draft: "opaque-draft"
        )
        let request = IPCRequest(id: id, method: .ruleSave(params))
        let requestData = try IPCJSON.encode(request)
        let requestGolden =
            #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"ruleSave":{"draft":"opaque-draft","id":"ask-1","polarity":"block"}},"protocol":"rv.ipc.v1"}"#
        #expect(String(data: requestData, encoding: .utf8) == requestGolden)
        #expect(try IPCJSON.decode(IPCRequest.self, from: requestData) == request)

        let reply = RuleSaveReply(
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            waitResolved: true
        )
        let response = IPCResponse(id: id, result: .ruleSave(reply))
        let responseData = try IPCJSON.encode(response)
        let responseGolden =
            #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"ruleSave":{"ruleID":"core.git:reset-hard","waitResolved":true}}}"#
        #expect(String(data: responseData, encoding: .utf8) == responseGolden)
        #expect(try IPCJSON.decode(IPCResponse.self, from: responseData) == response)
    }

    @Test func oldEvaluateAndHookEvaluateEnvelopes_stillDecodeOnV1() throws {
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let evaluateRequest = IPCRequest(id: id, method: .evaluate(EvaluateParams(request: request)))
        let requestData = try IPCJSON.encode(evaluateRequest)
        let decodedRequest = try IPCJSON.decode(IPCRequest.self, from: requestData)
        #expect(decodedRequest == evaluateRequest)
        guard case .evaluate(let params) = decodedRequest.method else {
            Issue.record("old evaluate request must still decode as evaluate")
            return
        }
        #expect(params.clientSemver == nil)

        let evaluateResponse = IPCResponse(
            id: id,
            result: .evaluate(
                EvaluateReply(result: EvaluationResult(outcome: .plain, matchingView: "git status"))
            )
        )
        let responseData = try IPCJSON.encode(evaluateResponse)
        #expect(try IPCJSON.decode(IPCResponse.self, from: responseData) == evaluateResponse)

        let hookRequest = IPCRequest(
            id: id,
            method: .hookEvaluate(HookEvaluateParams(host: .grok, stdin: #"{"tool":"Bash"}"#))
        )
        #expect(try IPCJSON.decode(IPCRequest.self, from: IPCJSON.encode(hookRequest)) == hookRequest)
    }

    @Test func unknownMethod_stillErrors() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "protocol": ProtocolVersion.name,
            "method": ["notAMethod": ["host": "grok"]],
        ])
        #expect(throws: DecodingError.self) {
            try IPCJSON.decode(IPCRequest.self, from: data)
        }
    }

    @Test func protocolNameStaysRvIpcV1() {
        #expect(ProtocolVersion.name == "rv.ipc.v1")
    }

    private func assertTypedGitPushDraft(
        _ draft: String,
        polarity: String,
        branch: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(draft.contains("gitPush"), sourceLocation: sourceLocation)
        let data = try #require(draft.data(using: .utf8), sourceLocation: sourceLocation)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            sourceLocation: sourceLocation
        )
        #expect(object["v"] as? Int == 2, sourceLocation: sourceLocation)
        #expect(object["polarity"] as? String == polarity, sourceLocation: sourceLocation)
        #expect(object["fingerprint"] == nil, sourceLocation: sourceLocation)
        #expect(object["id"] == nil, sourceLocation: sourceLocation)
        #expect(object["command"] == nil, sourceLocation: sourceLocation)
        #expect(object["supportingCommand"] == nil, sourceLocation: sourceLocation)
        let predicate = try #require(
            object["predicate"] as? [String: Any],
            sourceLocation: sourceLocation
        )
        let gitPush = try #require(
            predicate["gitPush"] as? [String: Any],
            sourceLocation: sourceLocation
        )
        #expect(gitPush["branch"] as? String == branch, sourceLocation: sourceLocation)
        #expect(gitPush["force"] as? String == "force", sourceLocation: sourceLocation)
    }

    private func assertRulePreviewWireOmitsCommand(
        _ data: Data,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let text = try #require(String(data: data, encoding: .utf8), sourceLocation: sourceLocation)
        #expect(text.contains("supportingCommand") == false, sourceLocation: sourceLocation)
        #expect(text.contains("ghp_secret") == false, sourceLocation: sourceLocation)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            sourceLocation: sourceLocation
        )
        assertNoCommandKeys(object, sourceLocation: sourceLocation)
    }

    private func assertNoCommandKeys(
        _ object: Any,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch object {
        case let dict as [String: Any]:
            #expect(dict["command"] == nil, sourceLocation: sourceLocation)
            #expect(dict["supportingCommand"] == nil, sourceLocation: sourceLocation)
            for value in dict.values {
                assertNoCommandKeys(value, sourceLocation: sourceLocation)
            }
        case let array as [Any]:
            for value in array {
                assertNoCommandKeys(value, sourceLocation: sourceLocation)
            }
        default:
            break
        }
    }
}
