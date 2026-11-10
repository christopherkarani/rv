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
