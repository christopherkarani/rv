import Foundation
import RVDomain
import Testing
@testable import RVIPC

/// Allow-once redeem over IPC across an upgrade. An rvd from before rvd
/// showed its own owner prompt planted a grant for a pinned CLI with no
/// owner check, and it plants before it replies, so a reply-side check
/// comes too late. The request therefore travels under a key such an rvd
/// cannot decode ("unknown IPCMethod": refused, nothing planted), and a
/// current rvd refuses the old key the same way.
@Suite("Allow-once redeem wire")
struct AllowOnceRedeemWireTests {
    private func params() throws -> AttestTTYRedemptionParams {
        AttestTTYRedemptionParams(
            fingerprint: GrantFingerprint(rawValue: String(repeating: "a", count: 64)),
            cwd: try #require(WorkingDirectory(validating: "/tmp/ws")),
            codeHash: CodeHash(rawValue: String(repeating: "b", count: 64)),
            clientSemver: "1.0.0")
    }

    @Test func requestTravelsUnderTheOwnerCheckedKeyOnly() throws {
        let data = try JSONEncoder().encode(IPCMethod.attestTTYRedemption(try params()))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Array(object.keys) == ["redeemAllowOnceOwnerChecked"])
        let method = try JSONDecoder().decode(IPCMethod.self, from: data)
        #expect(method == .attestTTYRedemption(try params()))
    }

    @Test func theOldKeyIsRefusedNotDecoded() throws {
        // What an old CLI sends. A current rvd must not plant for it: the
        // old CLI ran its own prompt, which rvd cannot see.
        let inner = try JSONEncoder().encode(try params())
        let innerObject = try JSONSerialization.jsonObject(with: inner)
        let legacy = try JSONSerialization.data(withJSONObject: ["attestTTYRedemption": innerObject])
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(IPCMethod.self, from: legacy)
        }
    }

    @Test func plantedReplySaysHowTheOwnerWasChecked() throws {
        let reply = AttestTTYRedemptionReply(planted: true, epoch: "e", presence: .daemonPrompt)
        let decoded = try JSONDecoder().decode(
            AttestTTYRedemptionReply.self, from: JSONEncoder().encode(reply))
        #expect(decoded == reply)
        #expect(decoded.presence == .daemonPrompt)
    }
}
