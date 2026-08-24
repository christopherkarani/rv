import Foundation
import Testing
@testable import RVIPC

struct IPCErrorGoldenFrameTests {
    @Test func protocolSkewHandshakeRequiredEncodesLegacyWireString() throws {
        let encoded = try IPCJSON.encode(IPCError.protocolSkew(.handshakeRequired))
        #expect(String(data: encoded, encoding: .utf8) == #"{"protocolSkew":"handshake required"}"#)
    }

    @Test func protocolSkewCasesEncodeLegacyWireStrings() throws {
        let cases: [(SkewReason, String)] = [
            (.protocolSkew, "protocol"),
            (.majorVersion, "major version"),
            (.corePacksUnavailable, "core packs unavailable"),
            (.handshakeRequired, "handshake required"),
        ]
        for (reason, wire) in cases {
            let encoded = try IPCJSON.encode(IPCError.protocolSkew(reason))
            #expect(String(data: encoded, encoding: .utf8) == #"{"protocolSkew":"\#(wire)"}"#)
            #expect(try IPCJSON.decode(IPCError.self, from: encoded) == .protocolSkew(reason))
        }
    }

    @Test func unknownProtocolSkewStringFailsDecode() throws {
        let data = Data(#"{"protocolSkew":"something_new"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try IPCJSON.decode(IPCError.self, from: data)
        }
    }
}
