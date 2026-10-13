import Foundation
import Testing
import RVDomain
@testable import RVIPC

/// Byte-exact goldens for the `rv.ipc.v1` SDK wire (`sdk/WIRE.md`).
///
/// Any change to these bytes is a wire change and requires a version decision
/// per `sdk/VERSIONING.md`. Non-Swift SDK test suites embed the same bytes.
/// Complements `IPCErrorGoldenFrameTests` (all error bytes),
/// `HookEvaluateRoundTripTests` (hookEvaluate request/response bytes), and
/// `EnvelopeRoundTripTests` (`allSamples` round-trips).
struct SDKVectorTests {
    private static let id = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    @Test func handshakeFrames_bytesMatchGolden() throws {
        let cases: [(String, String)] = [
            ("hello", #"{"clientSemver":"1.0.0","protocol":"rv.ipc.v1"}"#),
            ("ack-ok", #"{"ok":true,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}"#),
            (
                "ack-protocol",
                #"{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","skewReason":"protocol"}"#
            ),
            (
                "ack-major",
                #"{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","skewReason":"major version"}"#
            ),
            (
                "ack-packs",
                #"{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","skewReason":"core packs unavailable"}"#
            ),
        ]
        let values: [String: any Encodable] = [
            "hello": Hello(),
            "ack-ok": HelloAck(status: .ok),
            "ack-protocol": HelloAck(status: .skew(.protocolSkew)),
            "ack-major": HelloAck(status: .skew(.majorVersion)),
            "ack-packs": HelloAck(status: .skew(.corePacksUnavailable)),
        ]
        for (name, golden) in cases {
            let data = try IPCJSON.encode(values[name]!)
            #expect(
                String(data: data, encoding: .utf8) == golden,
                "wire change: \(name)"
            )
        }
    }

    @Test func methodRequestFrames_bytesMatchGolden() throws {
        let id = Self.id
        let evaluateParams =
            #"{"request":{"command":"git reset --hard","enabledPacks":["core.filesystem","core.git","system.disk"]}}"#
        let goldens: [String: String] = [
            "evaluate":
                #"{"id":"\#(id)","method":{"evaluate":\#(evaluateParams)},"protocol":"rv.ipc.v1"}"#,
            "explain":
                #"{"id":"\#(id)","method":{"explain":\#(evaluateParams)},"protocol":"rv.ipc.v1"}"#,
            "classify":
                #"{"id":"\#(id)","method":{"classify":\#(evaluateParams)},"protocol":"rv.ipc.v1"}"#,
            "listPacks":
                #"{"id":"\#(id)","method":{"listPacks":{}},"protocol":"rv.ipc.v1"}"#,
            "setPackEnabled":
                #"{"id":"\#(id)","method":{"setPackEnabled":{"enabled":true,"id":"core.git"}},"protocol":"rv.ipc.v1"}"#,
            "doctorSnapshot":
                #"{"id":"\#(id)","method":{"doctorSnapshot":{}},"protocol":"rv.ipc.v1"}"#,
            "pendingList":
                #"{"id":"\#(id)","method":{"pendingList":{}},"protocol":"rv.ipc.v1"}"#,
            "pendingWatch":
                #"{"id":"\#(id)","method":{"pendingWatch":{"afterGeneration":0}},"protocol":"rv.ipc.v1"}"#,
            "pendingResolve":
                #"{"id":"\#(id)","method":{"pendingResolve":{"decision":"deny","fingerprint":"shell:git","id":"ask-1","identity":{"agent":"pi","session":"sess"}}},"protocol":"rv.ipc.v1"}"#,
            "rulePreview":
                #"{"id":"\#(id)","method":{"rulePreview":{"id":"ask-1","polarity":"allow"}},"protocol":"rv.ipc.v1"}"#,
            "ruleSave":
                #"{"id":"\#(id)","method":{"ruleSave":{"draft":"opaque-draft","id":"ask-1","polarity":"block"}},"protocol":"rv.ipc.v1"}"#,
        ]
        #expect(IPCMethod.allSamples.count == goldens.count)
        for sample in IPCMethod.allSamples {
            let data = try IPCJSON.encode(IPCRequest(id: sample.id, method: sample.method))
            #expect(
                String(data: data, encoding: .utf8) == goldens[sample.key],
                "wire change: req-\(sample.key)"
            )
        }
    }

    @Test func resultResponseFrames_bytesMatchGolden() throws {
        let id = Self.id
        let denyResult =
            #"{"decision":{"decision":"deny","reason":"destroys uncommitted changes","ruleID":"core.git:reset-hard"},"matchingView":"","quickRejected":false}"#
        let goldens: [String: String] = [
            "evaluate":
                #"{"id":"\#(id)","protocol":"rv.ipc.v1","result":{"evaluate":{"result":\#(denyResult),"serviceSemver":"1.0.0","via":"xpc"}}}"#,
            "explain":
                #"{"id":"\#(id)","protocol":"rv.ipc.v1","result":{"explain":{"normalized":"git reset --hard","packID":"core.git","result":\#(denyResult),"ruleID":"core.git:reset-hard","stages":[{"elapsedMs":0.1,"name":"normalize"}],"suggestion":"Run it in Terminal, or rv allow-once."}}}"#,
            "classify":
                #"{"id":"\#(id)","protocol":"rv.ipc.v1","result":{"classify":{"decision":{"decision":"deny","reason":"destroys uncommitted changes","ruleID":"core.git:reset-hard"},"packID":"core.git","reasons":[],"risk":"high","ruleID":"core.git:reset-hard","suggestions":[]}}}"#,
            "listPacks":
                #"{"id":"\#(id)","protocol":"rv.ipc.v1","result":{"listPacks":{"enabledCount":1,"packs":[{"bundled":true,"enabled":true,"id":"core.git"}],"totalCount":1}}}"#,
            "setPackEnabled":
                #"{"id":"\#(id)","protocol":"rv.ipc.v1","result":{"setPackEnabled":{"pack":{"bundled":true,"enabled":false,"id":"core.git"}}}}"#,
            "doctorSnapshot":
                #"{"id":"\#(id)","protocol":"rv.ipc.v1","result":{"doctorSnapshot":{"checks":[{"id":"xpc","message":"listener","status":"ok"}],"idleExitSeconds":300,"keepAlive":false,"label":"dev.rv.evaluate","packsEnabled":["core.git"],"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","state":"running"}}}"#,
            "error":
                #"{"id":"\#(id)","protocol":"rv.ipc.v1","result":{"error":{"packNotFound":"core.unknown"}}}"#,
            "pendingList":
                #"{"id":"\#(id)","protocol":"rv.ipc.v1","result":{"pendingList":{"generation":1,"items":[{"actionKind":"git push","fingerprint":"shell:git","folder":"ws","host":"pi","id":"ask-1","identity":{"agent":"pi","session":"sess"}}]}}}"#,
            "pendingWatch":
                #"{"id":"\#(id)","protocol":"rv.ipc.v1","result":{"pendingWatch":{"generation":1,"items":[]}}}"#,
            "pendingResolve":
                #"{"id":"\#(id)","protocol":"rv.ipc.v1","result":{"pendingResolve":{"id":"ask-1","terminal":true}}}"#,
            "rulePreview":
                #"{"id":"\#(id)","protocol":"rv.ipc.v1","result":{"rulePreview":{"allowedToSave":true,"draft":"opaque-draft","sentence":"Always allow git push in this folder."}}}"#,
            "ruleSave":
                #"{"id":"\#(id)","protocol":"rv.ipc.v1","result":{"ruleSave":{"ruleID":"core.git:reset-hard","waitResolved":true}}}"#,
        ]
        #expect(IPCResult.allSamples.count == goldens.count)
        for sample in IPCResult.allSamples {
            let data = try IPCJSON.encode(IPCResponse(id: sample.id, result: sample.result))
            #expect(
                String(data: data, encoding: .utf8) == goldens[sample.key],
                "wire change: resp-\(sample.key)"
            )
        }
    }
}
