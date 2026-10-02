import Foundation
import RVDomain
import Testing
@testable import RVIPC

/// Redemption wire contract: commit/response codecs, keys, bounds, and
/// malformed-input rejection. DTOs are data only; decoding never implies
/// authority.
@Suite("Operator redeem wire")
struct OperatorRedeemWireRoundTripTests {
    private static let digest = String(repeating: "a", count: 64)

    private func commit(kind: String = "launchAgent") -> HostRedeemCommitDTO {
        HostRedeemCommitDTO(
            authorizationID: UUID(),
            workspaceSessionID: UUID(),
            hostID: UUID(),
            generation: UUID(),
            preparedID: UUID(),
            intentDigestHex: Self.digest,
            kind: kind,
            definitionID: kind == "launchAgent" ? "test-agent" : nil,
            revisionDigest: kind == "launchAgent" ? Self.digest : nil)
    }

    @Test func commitRoundTrips() throws {
        for value in [commit(kind: "launchAgent"), commit(kind: "launchCustom")] {
            let data = try JSONEncoder().encode(value)
            #expect(data.count < HostRedeemWire.maxBodyBytes)
            #expect(try JSONDecoder().decode(HostRedeemCommitDTO.self, from: data) == value)
        }
    }

    @Test func responseRoundTrips() throws {
        let values = [
            HostRedeemResponseDTO(
                accepted: true, runtimeSessionID: UUID(), agentInstanceID: UUID()),
            HostRedeemResponseDTO(accepted: true, error: "launchFailed"),
            HostRedeemResponseDTO(accepted: true, error: "alreadyAccepted"),
            HostRedeemResponseDTO(accepted: false, error: "unknown"),
        ]
        for value in values {
            let data = try JSONEncoder().encode(value)
            #expect(data.count < HostRedeemWire.maxBodyBytes)
            #expect(try JSONDecoder().decode(HostRedeemResponseDTO.self, from: data) == value)
        }
    }

    @Test func malformedCommitRejected() {
        let garbage: HostRedeemCommitDTO? = try? JSONDecoder().decode(
            HostRedeemCommitDTO.self, from: Data("not json".utf8))
        #expect(garbage == nil)
        // Unknown kind decodes (it is data) but never validates: the host
        // redeem handler rejects it before any supervisor contact.
        let tampered = """
            {"authorizationID":"\(UUID().uuidString)",\
            "workspaceSessionID":"\(UUID().uuidString)",\
            "hostID":"\(UUID().uuidString)",\
            "generation":"\(UUID().uuidString)",\
            "preparedID":"\(UUID().uuidString)",\
            "intentDigestHex":"\(Self.digest)",\
            "kind":"launchEverything",\
            "definitionID":null,"revisionDigest":null}
            """
        let decoded = try? JSONDecoder().decode(
            HostRedeemCommitDTO.self, from: Data(tampered.utf8))
        #expect(decoded?.kind == "launchEverything")
    }

    @Test func wireKeysAreNamespaced() {
        #expect(HostRedeemWire.redeemKey == "rv.host-redeem")
        #expect(HostRedeemWire.redeemKey != HostPrepareWire.prepareKey)
        #expect(HostRedeemWire.maxBodyBytes == 1_048_576)
    }

    @Test func statusReplyStaysBackwardCompatible() throws {
        // Old payloads (status only) decode with nil launch detail; new
        // payloads round-trip the attribution fields.
        let legacy = """
            {"operationID":"\(UUID().uuidString)","status":"consumed"}
            """
        let decoded = try JSONDecoder().decode(
            ProposalStatusReply.self, from: Data(legacy.utf8))
        #expect(decoded.status == "consumed")
        #expect(decoded.launchResult == nil)
        #expect(decoded.runtimeSessionID == nil)
        #expect(decoded.agentInstanceID == nil)
        let full = ProposalStatusReply(
            operationID: UUID(), status: "consumed", launchResult: "launched",
            runtimeSessionID: UUID(), agentInstanceID: UUID())
        let data = try JSONEncoder().encode(full)
        #expect(try JSONDecoder().decode(ProposalStatusReply.self, from: data) == full)
    }
}
