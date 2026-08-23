import Foundation
import Testing
import RVDomain
@testable import RVIPC

struct HookEvaluateRoundTripTests {
    @Test func hookEvaluateRequestFrame_bytesMatchGolden() throws {
        #expect(ProtocolVersion.serviceSemver == "1.0.0")
        let params = HookEvaluateParams(
            host: .grok,
            stdin: #"{"tool":"Bash"}"#,
            clientSemver: ProtocolVersion.serviceSemver
        )
        let id = try #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let request = IPCRequest(id: id, method: .hookEvaluate(params))
        let data = try IPCJSON.encode(request)
        let golden = #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"hookEvaluate":{"clientSemver":"1.0.0","host":"grok","stdin":"{\"tool\":\"Bash\"}"}},"protocol":"rv.ipc.v1"}"#
        #expect(String(data: data, encoding: .utf8) == golden)
    }

    @Test func hookEvaluateReplyFrame_bytesMatchGolden() throws {
        let reply = HookEvaluateReply(stdout: "", exitCode: 1)
        let id = try #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let response = IPCResponse(id: id, result: .hookEvaluate(reply))
        let data = try IPCJSON.encode(response)
        let golden = #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"hookEvaluate":{"exitCode":1,"serviceSemver":"1.0.0","stdout":"","via":"xpc"}}}"#
        #expect(String(data: data, encoding: .utf8) == golden)
    }

    @Test func hookEvaluateParams_roundTripsHostStdinAndClientSemver() throws {
        let params = HookEvaluateParams(
            host: .grok,
            stdin: #"{"tool":"Bash"}"#,
            clientSemver: ProtocolVersion.serviceSemver
        )
        let id = try #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let request = IPCRequest(id: id, method: .hookEvaluate(params))
        let data = try IPCJSON.encode(request)
        #expect(try IPCJSON.decode(IPCRequest.self, from: data) == request)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["protocol"] as? String == ProtocolVersion.name)
        #expect(ProtocolVersion.name == "rv.ipc.v1")
        let method = try #require(object["method"] as? [String: Any])
        let body = try #require(method["hookEvaluate"] as? [String: Any])
        #expect(body["host"] as? String == "grok")
        #expect(body["stdin"] as? String == #"{"tool":"Bash"}"#)
        #expect(body["clientSemver"] as? String == ProtocolVersion.serviceSemver)
        #expect(String(data: data, encoding: .utf8)?.contains("isDenied") == false)
    }

    @Test func hookEvaluateParams_omittedClientSemverIsNil() throws {
        let omitted = try IPCJSON.encode(HookEvaluateParams(host: .pi, stdin: ""))
        let omittedObject = try #require(JSONSerialization.jsonObject(with: omitted) as? [String: Any])
        #expect(omittedObject["clientSemver"] == nil)
        #expect(try IPCJSON.decode(HookEvaluateParams.self, from: omitted).clientSemver == nil)

        let oldShape = try JSONSerialization.data(withJSONObject: [
            "host": "opencode",
            "stdin": "ls",
        ])
        let decoded = try IPCJSON.decode(HookEvaluateParams.self, from: oldShape)
        #expect(decoded.host == .opencode)
        #expect(decoded.stdin == "ls")
        #expect(decoded.clientSemver == nil)
    }

    @Test func hookEvaluateParams_unknownHostFailsDecodeWithDataCorrupted() throws {
        let hostile = try JSONSerialization.data(withJSONObject: [
            "host": "nope",
            "stdin": "ls",
        ])
        do {
            _ = try IPCJSON.decode(HookEvaluateParams.self, from: hostile)
            Issue.record("unknown host string must fail decode")
        } catch let error as DecodingError {
            guard case .dataCorrupted = error else {
                Issue.record("unknown host must be dataCorrupted, got \(error)")
                return
            }
        }
    }

    @Test func hookEvaluateReply_roundTripsStdoutExitViaAndServiceSemver() throws {
        let reply = HookEvaluateReply(stdout: "blocked", exitCode: 0)
        let id = try #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let response = IPCResponse(id: id, result: .hookEvaluate(reply))
        let data = try IPCJSON.encode(response)
        #expect(try IPCJSON.decode(IPCResponse.self, from: data) == response)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["protocol"] as? String == ProtocolVersion.name)
        let result = try #require(object["result"] as? [String: Any])
        let body = try #require(result["hookEvaluate"] as? [String: Any])
        #expect(body["stdout"] as? String == "blocked")
        #expect(body["exitCode"] as? Int == 0)
        #expect(body["via"] as? String == "xpc")
        #expect(body["serviceSemver"] as? String == ProtocolVersion.serviceSemver)
        #expect(try IPCJSON.decode(HookEvaluateReply.self, from: IPCJSON.encode(reply)).via == .xpc)
    }

    @Test func hookEvaluateReply_viaMustBeXpc() throws {
        let data = try IPCJSON.encode(HookEvaluateReply(stdout: "", exitCode: 0))
        #expect(try IPCJSON.decode(HookEvaluateReply.self, from: data).via == .xpc)

        for badVia in ["inProcess", "bogus"] {
            var spoofed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            spoofed["via"] = badVia
            let bad = try JSONSerialization.data(withJSONObject: spoofed)
            #expect(throws: DecodingError.self) {
                try IPCJSON.decode(HookEvaluateReply.self, from: bad)
            }
        }
    }

    @Test func hookEvaluateReply_serviceSemverIsAdditiveOptionalOnV1() throws {
        let data = try IPCJSON.encode(HookEvaluateReply(stdout: "", exitCode: 0))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "serviceSemver")
        let omitted = try JSONSerialization.data(withJSONObject: object)
        let decoded = try IPCJSON.decode(HookEvaluateReply.self, from: omitted)
        #expect(decoded.via == .xpc)
        #expect(decoded.serviceSemver == nil)
        #expect(decoded.exitCode == 0)
        #expect(decoded.stdout == "")
    }

    @Test func oldEvaluateEnvelopes_stillDecodeOnV1() throws {
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let id = try #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
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
}
