import Foundation
import Testing
@testable import RVPolicy

@Suite("ManagedPolicy dotenv")
struct DotenvPolicyTests {
    @Test func dotenvIsAKnownKindAndDefaultAllowed() {
        #expect(ManagedPolicy.secretSourceKinds.contains("dotenv"))
        #expect(ManagedPolicy().allowsSecretSource("dotenv"))
    }

    @Test func allowedSourcesWithoutDotenvForbidsIt() throws {
        let policy = try ManagedPolicy.decode(Data("""
            {"version":1,"secrets":{"allowedSources":["keychain","vault"]}}
            """.utf8)).get()
        #expect(policy.allowsSecretSource("dotenv") == false)
        #expect(policy.allowsSecretSource("keychain"))
        let withDotenv = try ManagedPolicy.decode(Data("""
            {"version":1,"secrets":{"allowedSources":["keychain","dotenv"]}}
            """.utf8)).get()
        #expect(withDotenv.allowsSecretSource("dotenv"))
    }

    @Test func typoKindStillRejected() {
        guard case .failure = ManagedPolicy.decode(Data("""
            {"version":1,"secrets":{"allowedSources":["dotEnv"]}}
            """.utf8))
        else {
            Issue.record("unknown kind must stay an error")
            return
        }
    }
}
