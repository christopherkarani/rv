import Foundation
import Testing
import RVDomain
import RVIPC
@testable import RVCLI

/// Owner calls must reach rvd on installs with no peer-trust manifest, so
/// they verify rvd the way hooks do (the hook-consult session: the
/// manifest when installed, otherwise the pinned sibling `rvd`), never the
/// manifest-only session that refuses every manifest-free rvd.
struct OwnerCallTransportTests {
    private static let ack = HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok)

    @Test func confirmOwnerActionVerifiesRvdLikeAHook() async throws {
        let transport = ScriptedTransport(
            ack: Self.ack,
            responseResult: .confirmOwnerAction(ConfirmOwnerActionReply(outcome: .declined))
        )
        let client = try isolatedClient(transport: transport)
        _ = await client.confirmOwnerAction(ConfirmOwnerActionParams(
            summary: "set safety to strict", proof: nil, clientSemver: ProtocolVersion.serviceSemver))
        #expect(transport.sendCount == 1)
        #expect(transport.hookConsultCount == 1)
        #expect(transport.lastSendTimeoutMs == ServiceClient.confirmOwnerActionTimeoutMs)
    }

    @Test func mintAllowOnceVerifiesRvdLikeAHook() async throws {
        let transport = ScriptedTransport(
            ack: Self.ack,
            responseResult: .mintAllowOnce(MintAllowOnceReply(
                code: nil, ownerCheck: ConfirmOwnerActionReply(outcome: .declined)))
        )
        let client = try isolatedClient(transport: transport)
        _ = await client.mintAllowOnce(MintAllowOnceParams(
            command: "git push", cwd: try #require(WorkingDirectory(rawValue: "/tmp")), clientSemver: ProtocolVersion.serviceSemver))
        #expect(transport.hookConsultCount == 1)
        #expect(transport.lastSendTimeoutMs == ServiceClient.confirmOwnerActionTimeoutMs)
    }

    @Test func attestTTYRedemptionVerifiesRvdLikeAHook() async throws {
        let transport = ScriptedTransport(
            ack: Self.ack,
            responseResult: .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: false, epoch: "e", ownerCheck: ConfirmOwnerActionReply(outcome: .declined)))
        )
        let client = try isolatedClient(transport: transport)
        _ = await client.attestTTYRedemption(AttestTTYRedemptionParams(
            fingerprint: GrantFingerprint(rawValue: "f"),
            cwd: try #require(WorkingDirectory(rawValue: "/tmp")),
            codeHash: CodeHash(rawValue: "c"),
            clientSemver: ProtocolVersion.serviceSemver
        ))
        #expect(transport.hookConsultCount == 1)
        #expect(transport.lastSendTimeoutMs == ServiceClient.confirmOwnerActionTimeoutMs)
    }
}

/// Version skew: an rvd from before rvd showed its own prompt approves a
/// `.cli` caller with no owner check at all. Only a current rvd says how
/// it checked the owner, so the CLI refuses an approval that does not.
struct OwnerConfirmationPresenceTests {
    #if canImport(LocalAuthentication)
    private static let expected = ConfirmOwnerActionReply.Presence.daemonPrompt
    private static let other = ConfirmOwnerActionReply.Presence.password
    #else
    private static let expected = ConfirmOwnerActionReply.Presence.password
    private static let other = ConfirmOwnerActionReply.Presence.daemonPrompt
    #endif

    @Test func anOldStyleApprovalWithoutPresenceIsRefused() throws {
        let decoded = try JSONDecoder().decode(ConfirmOwnerActionReply.self, from: Data(#"{"outcome":"approved"}"#.utf8))
        #expect(decoded.presence == nil)
        #expect(throws: (any Error).self) {
            try OwnerConfirmation.accept(.success(decoded), summary: "set safety to normal")
        }
    }

    @Test func anApprovalNamingTheOtherPlatformsCheckIsRefused() {
        #expect(throws: (any Error).self) {
            try OwnerConfirmation.accept(
                .success(ConfirmOwnerActionReply(outcome: .approved, presence: Self.other)), summary: "x")
        }
    }

    @Test func aCurrentApprovalProceeds() throws {
        try OwnerConfirmation.accept(
            .success(ConfirmOwnerActionReply(outcome: .approved, presence: Self.expected)), summary: "x")
    }

    @Test func declinedAndUnreachableAreRefused() {
        #expect(throws: (any Error).self) {
            try OwnerConfirmation.accept(.success(ConfirmOwnerActionReply(outcome: .declined)), summary: "x")
        }
        #expect(throws: (any Error).self) {
            try OwnerConfirmation.accept(.failure(.noTransport), summary: "x")
        }
    }

    @Test func presenceRoundTripsOnTheWire() throws {
        let reply = ConfirmOwnerActionReply(outcome: .approved, presence: .daemonPrompt)
        let data = try JSONEncoder().encode(reply)
        #expect(String(decoding: data, as: UTF8.self).contains("\"presence\":\"daemonPrompt\""))
        #expect(try JSONDecoder().decode(ConfirmOwnerActionReply.self, from: data) == reply)
    }
}
