import Foundation
import Testing
import RVDomain
@testable import RVIPC

/// Byte pins for the error/stage frames WV-T2 reshapes. Captured before the
/// payload change; later commits must hold or deliberately re-pin these bytes
/// alongside their producers.
struct ErrorPayloadGoldenTests {
    private static let fixedID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    @Test func protocolSkewHandshakeRequired_errorFrameBytesMatchGolden() throws {
        let id = try #require(UUID(uuidString: Self.fixedID))
        let response = IPCResponse(id: id, result: .error(.protocolSkew("handshake required")))
        let data = try IPCJSON.encode(response)
        let golden = #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"error":{"protocolSkew":"handshake required"}}}"#
        #expect(String(data: data, encoding: .utf8) == golden)
    }

    @Test func engineHookFailed_errorFrameBytesMatchGolden() throws {
        let id = try #require(UUID(uuidString: Self.fixedID))
        let response = IPCResponse(id: id, result: .error(.engine("hook evaluate failed")))
        let data = try IPCJSON.encode(response)
        let golden = #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"error":{"engine":"hook evaluate failed"}}}"#
        #expect(String(data: data, encoding: .utf8) == golden)
    }

    @Test func enginePackMutationFailed_errorFrameBytesMatchGolden() throws {
        let id = try #require(UUID(uuidString: Self.fixedID))
        let response = IPCResponse(id: id, result: .error(.engine("pack enable failed")))
        let data = try IPCJSON.encode(response)
        let golden = #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"error":{"engine":"pack enable failed"}}}"#
        #expect(String(data: data, encoding: .utf8) == golden)
    }

    @Test func helloAckSkewReasons_bytesMatchGolden() throws {
        for (reason, raw) in [(SkewReason.protocolSkew, "protocol"), (SkewReason.majorVersion, "major version")] {
            let ack = HelloAck(ok: false, skewReason: reason)
            let data = try IPCJSON.encode(ack)
            let golden = "{\"ok\":false,\"protocol\":\"rv.ipc.v1\",\"serviceSemver\":\"1.0.0\",\"skewReason\":\"\(raw)\"}"
            #expect(String(data: data, encoding: .utf8) == golden)
            #expect(reason.rawValue == raw)
        }
    }

    @Test func explainReplyStages_stageFrameBytesMatchGolden() throws {
        let stage = ExplainStage(name: "normalize", elapsedMs: 0.1)
        let stageData = try IPCJSON.encode(stage)
        #expect(String(data: stageData, encoding: .utf8) == #"{"elapsedMs":0.1,"name":"normalize"}"#)

        let reply = ExplainReply(
            result: EvaluationResult(outcome: .plain),
            normalized: "git status",
            stages: [stage]
        )
        let data = try IPCJSON.encode(reply)
        let frame = try #require(String(data: data, encoding: .utf8))
        #expect(frame.contains(#""stages":[{"elapsedMs":0.1,"name":"normalize"}]"#))
        #expect(try IPCJSON.decode(ExplainReply.self, from: data) == reply)
    }

    @Test func legacyAllowOnceConsumeRequestKey_stillDecodesIntoTheMethod() throws {
        let legacy = try JSONSerialization.data(withJSONObject: [
            "id": Self.fixedID,
            "protocol": ProtocolVersion.name,
            "method": ["allowOnceConsume": ["command": "git reset --hard", "cwd": "/tmp/ws"]],
        ])
        let decoded = try IPCJSON.decode(IPCRequest.self, from: legacy)
        guard case .allowOnceConsume(let params) = decoded.method else {
            Issue.record("legacy allowOnceConsume frame must decode into its method today")
            return
        }
        #expect(params.command == "git reset --hard")
        #expect(params.cwd == "/tmp/ws")
    }
}
