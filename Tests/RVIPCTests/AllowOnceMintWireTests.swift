import Foundation
import RVDomain
import Testing
@testable import RVIPC

/// `rv allow-once mint` over IPC: the exact command and cwd go to rvd, and
/// the reply carries the code, the owner check, or why nothing was minted.
@Suite("Allow-once mint wire")
struct AllowOnceMintWireTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func requestRoundTripsWithTheExactCommand() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let methods: [IPCMethod] = [
            .mintAllowOnce(MintAllowOnceParams(
                command: #"LD_PRELOAD=/tmp/x.so git push --force "main""#, cwd: cwd, clientSemver: "1.0.0")),
            .mintAllowOnce(MintAllowOnceParams(
                command: "git reset --hard", cwd: cwd, clientSemver: "1.0.0",
                ownerProof: OwnerProof(password: "pw"))),
        ]
        for method in methods {
            #expect(try roundTrip(method) == method)
        }
    }

    @Test func replyRoundTrips() throws {
        let results: [IPCResult] = [
            .mintAllowOnce(MintAllowOnceReply(code: "abc123")),
            .mintAllowOnce(MintAllowOnceReply(
                ownerCheck: ConfirmOwnerActionReply(outcome: .proofRequired), promptText: "pre-arm a code to …")),
            .mintAllowOnce(MintAllowOnceReply(
                ownerCheck: ConfirmOwnerActionReply(outcome: .unavailable), notShowable: true)),
            .mintAllowOnce(MintAllowOnceReply(alreadyPending: true)),
        ]
        for result in results {
            #expect(try roundTrip(result) == result)
            #expect(MintAllowOnceCall.extract(result) != nil)
        }
        #expect(MintAllowOnceCall.extract(.error(.authorizationDenied)) == nil)
    }
}
