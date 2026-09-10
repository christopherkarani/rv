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

    @Test(arguments: [
        (IPCError.pendingNotFound, "pendingNotFound"),
        (IPCError.pendingAlreadyTerminal, "pendingAlreadyTerminal"),
        (IPCError.pendingIdentityMismatch, "pendingIdentityMismatch"),
        (IPCError.pendingFingerprintMismatch, "pendingFingerprintMismatch"),
        (IPCError.ruleDraftMismatch, "ruleDraftMismatch"),
        (IPCError.ruleHardStop, "ruleHardStop"),
    ])
    func pendingAndRuleUnitErrorsEncodeTrue(_ error: IPCError, _ key: String) throws {
        let encoded = try IPCJSON.encode(error)
        #expect(String(data: encoded, encoding: .utf8) == #"{"\#(key)":true}"#)
        #expect(try IPCJSON.decode(IPCError.self, from: encoded) == error)
    }

    @Test func existingUnitErrorsStayByteCompatible() throws {
        let cases: [(IPCError, String)] = [
            (.unknownMethod, "unknownMethod"),
            (.decodeFailed, "decodeFailed"),
            (.allowOnceNotFound, "allowOnceNotFound"),
            (.allowOnceAlreadyConsumed, "allowOnceAlreadyConsumed"),
            (.allowOnceExpired, "allowOnceExpired"),
        ]
        for (error, key) in cases {
            let encoded = try IPCJSON.encode(error)
            #expect(String(data: encoded, encoding: .utf8) == #"{"\#(key)":true}"#)
            #expect(try IPCJSON.decode(IPCError.self, from: encoded) == error)
        }
    }

    @Test(arguments: [
        (IPCError.hookEvaluateFailed, "hook evaluate failed"),
        (IPCError.packEnableFailed, "pack enable failed"),
        (IPCError.rulePinRequiresMatchingView, "rule pin requires a matching view"),
        (IPCError.pendingAllowOnceNotUnlockable, "pending allowOnce is not unlockable"),
        (IPCError.pendingCoordinatorUnavailable, "pending coordinator unavailable"),
    ])
    func namedEngineErrorsEncodeFrozenSentences(_ error: IPCError, _ sentence: String) throws {
        let encoded = try IPCJSON.encode(error)
        #expect(String(data: encoded, encoding: .utf8) == #"{"engine":"\#(sentence)"}"#)
        #expect(try IPCJSON.decode(IPCError.self, from: encoded) == error)
        #expect(try IPCJSON.decode(IPCError.self, from: Data("{\"engine\":\"\(sentence)\"}".utf8)) == error)
    }

    @Test func unknownEngineStringRemainsLeftoverEngine() throws {
        let data = Data(#"{"engine":"something the service never owned"}"#.utf8)
        #expect(try IPCJSON.decode(IPCError.self, from: data) == .engine("something the service never owned"))
        let encoded = try IPCJSON.encode(IPCError.engine("something the service never owned"))
        #expect(String(data: encoded, encoding: .utf8) == #"{"engine":"something the service never owned"}"#)
    }
}
