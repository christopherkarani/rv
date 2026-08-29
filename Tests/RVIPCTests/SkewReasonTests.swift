import Foundation
import Testing
import RVDomain
@testable import RVIPC

struct SkewReasonTests {
    @Test func goldenFramesEncodeByteIdenticalToLegacyStringWire() throws {
        let skewed = try #require(
            String(
                data: IPCJSON.encode(HelloAck(status: .skew(.corePacksUnavailable))),
                encoding: .utf8
            )
        )
        #expect(
            skewed == #"{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","skewReason":"core packs unavailable"}"#
        )

        let healthy = try #require(
            String(data: IPCJSON.encode(HelloAck(status: .ok)), encoding: .utf8)
        )
        #expect(healthy == #"{"ok":true,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}"#)
        #expect(healthy.contains("skewReason") == false)
    }

    @Test func rawValuesAreTheLegacyWireStrings() {
        #expect(SkewReason.protocolSkew.rawValue == "protocol")
        #expect(SkewReason.majorVersion.rawValue == "major version")
        #expect(SkewReason.corePacksUnavailable.rawValue == "core packs unavailable")
        #expect(SkewReason.handshakeRequired.rawValue == "handshake required")
    }

    @Test func bothCasesRoundTrip() throws {
        for reason in [
            SkewReason.protocolSkew,
            .majorVersion,
            .corePacksUnavailable,
            .handshakeRequired,
        ] {
            let ack = HelloAck(status: .skew(reason))
            #expect(try IPCJSON.decode(HelloAck.self, from: IPCJSON.encode(ack)) == ack)
        }
        let healthy = HelloAck(status: .ok)
        #expect(try IPCJSON.decode(HelloAck.self, from: IPCJSON.encode(healthy)) == healthy)
    }

    @Test func unknownReasonStringFailsDecodeInsteadOfYieldingNil() throws {
        let data = Data(
            #"{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","skewReason":"something_new"}"#.utf8
        )
        #expect(throws: DecodingError.self) {
            try IPCJSON.decode(HelloAck.self, from: data)
        }
    }

    @Test(arguments: [
        #"{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}"#,
        #"{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","skewReason":null}"#,
    ])
    func missingReasonThrows(json: String) {
        #expect(throws: DecodingError.self) {
            try IPCJSON.decode(HelloAck.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: [
        #"{"ok":true,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","skewReason":"protocol"}"#,
        #"{"ok":true,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","skewReason":null}"#,
    ])
    func okTrueWithSkewReasonThrows(json: String) {
        #expect(throws: DecodingError.self) {
            try IPCJSON.decode(HelloAck.self, from: Data(json.utf8))
        }
    }
}
