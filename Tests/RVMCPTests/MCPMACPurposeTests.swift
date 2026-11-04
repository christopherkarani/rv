import Foundation
import Testing
@testable import RVMCP

@Suite("MCP MAC purpose and verdict")
struct MCPMACPurposeTests {
    private static func bytes<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Captured from the `purpose: String` encoding before the type change.
    @Test(arguments: [
        (MCPMACPurpose.grant, "grant"), (.code, "code"), (.argumentKeys, "argument-keys"), (.mcpJSON, "mcp.json"),
    ])
    func requestBytesMatchTheStringEncoding(purpose: MCPMACPurpose, wire: String) throws {
        #expect(try Self.bytes(MCPCustodianRequest.mac(purpose: purpose, fields: ["a", "b"], createIfMissing: true))
            == #"{"mac":{"createIfMissing":true,"fields":["a","b"],"purpose":"\#(wire)"}}"#)
        #expect(try Self.bytes(MCPCustodianRequest.verify(candidate: "00", purpose: purpose, fields: ["a"]))
            == #"{"verify":{"candidate":"00","fields":["a"],"purpose":"\#(wire)"}}"#)
        #expect(try Self.bytes(MCPCustodianRequest.verify(candidate: nil, purpose: purpose, fields: []))
            == #"{"verify":{"fields":[],"purpose":"\#(wire)"}}"#)
    }

    @Test func verifyResponseBytesAreUnchanged() throws {
        #expect(try Self.bytes(MCPCustodianResponse.verify(true)) == #"{"verify":{"_0":true}}"#)
        #expect(try Self.bytes(MCPCustodianResponse.verify(false)) == #"{"verify":{"_0":false}}"#)
        #expect(try Self.bytes(MCPCustodianResponse.verify(nil)) == #"{"verify":{}}"#)
    }

    @Test func purposesRoundTripAndAreExactlyTheWireVocabulary() throws {
        #expect(Set(MCPMACPurpose.allCases.map(\.rawValue)) == ["grant", "code", "argument-keys", "mcp.json"])
        for purpose in MCPMACPurpose.allCases {
            let request = MCPCustodianRequest.verify(candidate: "00", purpose: purpose, fields: ["a"])
            #expect(try JSONDecoder().decode(MCPCustodianRequest.self, from: JSONEncoder().encode(request)) == request)
        }
    }

    /// Stored approval rows and mcp-integrity.json carry MACs computed over
    /// these literals, so the typed API must keep MAC'ing exactly them.
    @Test(arguments: [
        (MCPMACPurpose.grant, "grant"), (.code, "code"), (.argumentKeys, "argument-keys"), (.mcpJSON, "mcp.json"),
    ])
    func macsAreOverThePurposeStringsAlreadyStored(purpose: MCPMACPurpose, literal: String) throws {
        let signer = try #require(MCPSigner(key: [UInt8](repeating: 7, count: 32)))
        let signing = MCPApprovalSigning.inProcess(load: { signer }, loadOrCreate: { signer })
        let mac = try #require(signing.mac(purpose, ["a", "b"], true))
        #expect(mac == signer.mac(literal, ["a", "b"]))
        #expect(signing.verify(signer.mac(literal, ["a", "b"]), purpose, ["a", "b"]) == .valid)
    }

    @Test(arguments: ["enrollment", "bogus", "", "Grant"])
    func unknownPurposesFailToDecode(purpose: String) {
        let mac = Data(#"{"mac":{"createIfMissing":true,"fields":[],"purpose":"\#(purpose)"}}"#.utf8)
        let verify = Data(#"{"verify":{"candidate":"00","fields":[],"purpose":"\#(purpose)"}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MCPCustodianRequest.self, from: mac) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MCPCustodianRequest.self, from: verify) }
    }

    @Test func verdictMapsTheWireBoolOptional() {
        #expect(MCPMACVerdict(wire: true) == .valid)
        #expect(MCPMACVerdict(wire: false) == .forged)
        #expect(MCPMACVerdict(wire: nil) == .noKey)
        #expect(MCPMACVerdict.valid.wire == true)
        #expect(MCPMACVerdict.forged.wire == false)
        #expect(MCPMACVerdict.noKey.wire == nil)
    }
}
