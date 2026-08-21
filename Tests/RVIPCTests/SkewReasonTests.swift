import Foundation
import Testing
import RVDomain
@testable import RVIPC

struct SkewReasonTests {
    @Test func goldenFramesEncodeByteIdenticalToLegacyStringWire() throws {
        let skewed = try #require(
            String(
                data: IPCJSON.encode(HelloAck(ok: false, skewReason: .corePacksUnavailable)),
                encoding: .utf8
            )
        )
        #expect(
            skewed == #"{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","skewReason":"core packs unavailable"}"#
        )

        let healthy = try #require(
            String(data: IPCJSON.encode(HelloAck(ok: true)), encoding: .utf8)
        )
        #expect(healthy == #"{"ok":true,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}"#)
    }

    @Test func rawValuesAreTheLegacyWireStrings() {
        #expect(SkewReason.protocolSkew.rawValue == "protocol")
        #expect(SkewReason.corePacksUnavailable.rawValue == "core packs unavailable")
    }

    @Test func bothCasesRoundTrip() throws {
        for reason in [SkewReason.protocolSkew, .corePacksUnavailable] {
            let ack = HelloAck(ok: false, skewReason: reason)
            #expect(try IPCJSON.decode(HelloAck.self, from: IPCJSON.encode(ack)) == ack)
        }
    }

    @Test func unknownReasonStringFailsDecodeInsteadOfYieldingNil() throws {
        let data = Data(
            #"{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","skewReason":"something_new"}"#.utf8
        )
        #expect(throws: DecodingError.self) {
            try IPCJSON.decode(HelloAck.self, from: data)
        }
    }

    @Test func missingReasonDecodesAsNil() throws {
        let data = Data(
            #"{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}"#.utf8
        )
        let decoded = try IPCJSON.decode(HelloAck.self, from: data)
        #expect(decoded.skewReason == nil)
        #expect(decoded.ok == false)
    }
}
