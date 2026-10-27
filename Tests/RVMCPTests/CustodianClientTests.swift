import Foundation
import Synchronization
import Testing
@testable import RVMCP

@Suite("MCP custodian client seam")
struct CustodianClientTests {
    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-custodian-\(UUID().uuidString)")
    }

    @Test func unreachableCustodianFailsClosed() {
        let signing = MCPApprovalSigning.custodian(transport: { _ in nil })
        #expect(signing.honorsGrants)
        #expect(signing.status() == .unavailable)
        #expect(signing.mac("grant", ["a"], true) == nil)
        #expect(signing.verify("00", "grant", ["a"]) == nil)
    }

    @Test func custodianErrorsFailClosed() {
        let signing = MCPApprovalSigning.custodian(transport: { _ in .error(.unauthorized) })
        #expect(signing.status() == .unavailable)
        #expect(signing.mac("grant", ["a"], true) == nil)
        #expect(signing.verify("00", "grant", ["a"]) == nil)
    }

    @Test func mismatchedResponsesFailClosed() {
        let signing = MCPApprovalSigning.custodian(transport: { _ in .status(.enrolled) })
        #expect(signing.mac("grant", ["a"], true) == nil)
        #expect(signing.verify("00", "grant", ["a"]) == nil)
    }

    @Test func verifyTriStatePassesThrough() {
        let unknown = MCPApprovalSigning.custodian(transport: { _ in .verify(nil) })
        #expect(unknown.verify("00", "grant", ["a"]) == nil)
        let forged = MCPApprovalSigning.custodian(transport: { _ in .verify(false) })
        #expect(forged.verify("00", "grant", ["a"]) == false)
        let valid = MCPApprovalSigning.custodian(transport: { _ in .verify(true) })
        #expect(valid.verify("00", "grant", ["a"]) == true)
    }

    @Test func disallowedPurposesAndOversizedRequestsNeverReachTheCustodian() {
        let calls = Mutex(0)
        let signing = MCPApprovalSigning.custodian(transport: { _ in
            calls.withLock { $0 += 1 }
            return .mac("should-not-happen")
        })
        #expect(signing.mac("enrollment", ["check"], true) == nil)
        #expect(signing.mac("bogus", ["check"], true) == nil)
        #expect(signing.verify("00", "enrollment", ["check"]) == nil)
        #expect(signing.mac("grant", (0..<17).map { "f\($0)" }, true) == nil)
        #expect(signing.mac("grant", [String(repeating: "x", count: 65 * 1024)], true) == nil)
        #expect(signing.verify(String(repeating: "x", count: 129), "grant", ["a"]) == nil)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func custodianServiceRejectsBadRequests() {
        let service = MCPCustodianKeyService(signing: .unavailable)
        #expect(service.handle(.mac(purpose: "enrollment", fields: ["check"], createIfMissing: true)) == .error(.badRequest))
        #expect(service.handle(.verify(candidate: "00", purpose: "bogus", fields: [])) == .error(.badRequest))
        #expect(service.handle(.mac(purpose: "grant", fields: (0..<17).map { "f\($0)" }, createIfMissing: true)) == .error(.badRequest))
    }

    @Test func roundTripThroughInProcessCustodianNeverCreatesOnVerify() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MCPCustodianKeyService(signing: .file(configDirectory: directory))
        let signing = MCPApprovalSigning.custodian(transport: service.transport)
        let keyURL = directory.appendingPathComponent(MCPApprovalKeyIdentity.fileName)

        #expect(signing.status() == .notEnrolled)
        #expect(signing.verify("00", "grant", ["a"]) == nil)
        #expect(signing.mac("grant", ["a"], false) == nil)
        #expect(FileManager.default.fileExists(atPath: keyURL.path) == false)

        let mac = try #require(signing.mac("grant", ["a"], true))
        #expect(signing.status() == .enrolled)
        #expect(signing.verify(mac, "grant", ["a"]) == true)
        #expect(signing.verify(mac, "grant", ["b"]) == false)
        #expect(signing.verify(String(mac.dropLast()), "grant", ["a"]) == false)
        #expect(signing.verify(nil, "grant", ["a"]) == false)
    }

    @Test func wirePayloadsCarryNoKeyMaterial() throws {
        let key = [UInt8](repeating: 7, count: 32)
        let backend = MCPApprovalSigning.inProcess(
            load: { MCPSigner(key: key) }, loadOrCreate: { MCPSigner(key: key) })
        let service = MCPCustodianKeyService(signing: backend)
        let request = MCPCustodianRequest.mac(purpose: "grant", fields: ["a"], createIfMissing: true)
        let response = service.handle(request)
        let encoder = JSONEncoder()
        let keyHex = key.map { String(format: "%02x", $0) }.joined()
        let requestText = try String(decoding: encoder.encode(request), as: UTF8.self)
        let responseText = try String(decoding: encoder.encode(response), as: UTF8.self)
        #expect(requestText.contains(keyHex) == false)
        #expect(responseText.contains(keyHex) == false)
        // The response MAC equals what the in-process signer would produce:
        // key bytes stayed inside the service.
        let expected = try #require(MCPSigner(key: key)).mac("grant", ["a"])
        #expect(response == .mac(expected))
    }
}
