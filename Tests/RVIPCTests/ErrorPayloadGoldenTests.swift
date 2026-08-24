import Foundation
import Testing
import RVDomain
@testable import RVIPC

/// Byte pins for the error/stage frames WV-T2 reshapes. Pre-change bytes were
/// captured in the first commit of this ticket; these are the deliberate
/// post-change pins (skew bytes themselves are unchanged per CON-004).
struct ErrorPayloadGoldenTests {
    private static let fixedID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    @Test func handshakeRequired_errorFrameBytesMatchGolden() throws {
        let id = try #require(UUID(uuidString: Self.fixedID))
        let response = IPCResponse(id: id, result: .error(.handshakeRequired))
        let data = try IPCJSON.encode(response)
        let golden = #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"error":{"handshakeRequired":true}}}"#
        #expect(String(data: data, encoding: .utf8) == golden)
        #expect(try IPCJSON.decode(IPCResponse.self, from: data) == response)
    }

    @Test func hookFailed_errorFrameBytesMatchGolden() throws {
        let id = try #require(UUID(uuidString: Self.fixedID))
        let response = IPCResponse(id: id, result: .error(.hookFailed))
        let data = try IPCJSON.encode(response)
        let golden = #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"error":{"hookFailed":true}}}"#
        #expect(String(data: data, encoding: .utf8) == golden)
        #expect(try IPCJSON.decode(IPCResponse.self, from: data) == response)
    }

    @Test func packMutationFailed_errorFrameBytesMatchGolden() throws {
        let id = try #require(UUID(uuidString: Self.fixedID))
        let response = IPCResponse(id: id, result: .error(.packMutationFailed))
        let data = try IPCJSON.encode(response)
        let golden = #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"error":{"packMutationFailed":true}}}"#
        #expect(String(data: data, encoding: .utf8) == golden)
        #expect(try IPCJSON.decode(IPCResponse.self, from: data) == response)
    }

    @Test func protocolSkew_skewBytesAreWireStable() throws {
        let major = IPCResponse(
            id: try #require(UUID(uuidString: Self.fixedID)),
            result: .error(.protocolSkew(.majorVersion))
        )
        let data = try IPCJSON.encode(major)
        let golden = #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1","result":{"error":{"protocolSkew":"major version"}}}"#
        #expect(String(data: data, encoding: .utf8) == golden)

        let legacy = Data(#"{"protocolSkew":"major version"}"#.utf8)
        let decoded = try IPCJSON.decode(IPCError.self, from: legacy)
        #expect(decoded == .protocolSkew(.majorVersion))
        #expect(try IPCJSON.encode(decoded) == legacy)

        let classified = Data(#"{"protocolSkew":"core packs unavailable"}"#.utf8)
        #expect(try IPCJSON.decode(IPCError.self, from: classified) == .protocolSkew(.corePacksUnavailable))

        let unclassified = Data(#"{"protocolSkew":null}"#.utf8)
        let nilReason = try IPCJSON.decode(IPCError.self, from: unclassified)
        #expect(nilReason == .protocolSkew(nil))
        #expect(try IPCJSON.encode(nilReason) == unclassified)
    }

    @Test func protocolSkew_unknownReasonStringFailsDecode() throws {
        let hostile = Data(#"{"protocolSkew":"something_new"}"#.utf8)
        do {
            _ = try IPCJSON.decode(IPCError.self, from: hostile)
            Issue.record("unknown skew reason string must not decode")
        } catch let error as DecodingError {
            guard case .dataCorrupted = error else {
                Issue.record("unknown skew reason must be dataCorrupted, got \(error)")
                return
            }
        }
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
        let stage = ExplainStage(name: .normalize, elapsedMs: 0.1)
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

    @Test func explainStageNames_encodeAsTheirStableRawValues() throws {
        let stages: [(ExplainStep.ID, String)] = [
            (.normalize, "normalize"),
            (.quickReject, "quick-reject"),
            (.safe, "safe"),
            (.destructive, "destructive"),
            (.default, "default"),
        ]
        for (id, raw) in stages {
            let data = try IPCJSON.encode(ExplainStage(name: id, elapsedMs: 0))
            #expect(String(data: data, encoding: .utf8) == "{\"elapsedMs\":0,\"name\":\"\(raw)\"}")
        }
    }

    @Test func explainStage_unknownNameFailsDecodeAsDataCorrupted() throws {
        for bad in ["bogus", "Normalize", "", "normalize "] {
            let payload = try JSONSerialization.data(
                withJSONObject: ["name": bad, "elapsedMs": 0.1]
            )
            do {
                _ = try IPCJSON.decode(ExplainStage.self, from: payload)
                Issue.record("unknown ExplainStage name \(bad) must not decode")
            } catch let error as DecodingError {
                guard case .dataCorrupted = error else {
                    Issue.record("unknown stage name must be dataCorrupted, got \(error)")
                    return
                }
            }
        }
    }

    /// Retired phantom method: a legacy frame carrying its request key falls
    /// into the envelope decoder's terminal unknown-key branch instead of
    /// decoding into a method.
    @Test func legacyPhantomMethodRequestKey_failsDecode() throws {
        let legacyKey = "allowOnce" + "Consume"
        let legacy = try JSONSerialization.data(withJSONObject: [
            "id": Self.fixedID,
            "protocol": ProtocolVersion.name,
            "method": [legacyKey: ["command": "git reset --hard", "cwd": "/tmp/ws"]],
        ])
        do {
            _ = try IPCJSON.decode(IPCRequest.self, from: legacy)
            Issue.record("retired phantom method key must fail decode")
        } catch let error as DecodingError {
            guard case .dataCorrupted = error else {
                Issue.record("phantom method key must be dataCorrupted, got \(error)")
                return
            }
        }
    }
}
