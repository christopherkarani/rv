import Foundation
import RVDomain
import RVFileStore
import Testing
@testable import RVIsolation

@Suite("ScopedInvokeErrorProjection")
struct ScopedInvokeErrorProjectionTests {
    @Test func invokeFailureProjectsEveryArm() {
        let defect = MCPOpaqueDefect(correlationID: SecretsCorrelationID())
        let cases: [(ScopedInvokeError, MCPInvokeFailure)] = [
            (.principalRequired, .principalRequired),
            (.policyDenied(matchedPolicyId: "r1"), .policyDenied(matchedPolicyId: "r1")),
            (.policyDenied(matchedPolicyId: nil), .policyDenied(matchedPolicyId: nil)),
            (.unknownTool, .unknownTool),
            (.crossResource, .crossResource),
            (.invalidArguments(.malformed), .invalidArguments(.malformed)),
            (.elicitationTimeout, .elicitationTimeout),
            (.elicitationUnavailable, .elicitationUnavailable),
            (.credentialFailed(.providerDown("exec")), .credentialFailed(.providerDown("exec"))),
            (.auditFailed, .auditFailed),
            // The opaque payload drops: correlation stays server-side.
            (.internalError(defect), .opaque),
        ]
        for (error, expected) in cases {
            #expect(error.invokeFailure == expected, "\(error)")
        }
    }

    @Test func opaqueProjectionDropsDistinctCorrelations() {
        #expect(
            ScopedInvokeError.internalError(MCPOpaqueDefect(correlationID: SecretsCorrelationID())).invokeFailure
                == ScopedInvokeError.internalError(MCPOpaqueDefect(correlationID: SecretsCorrelationID())).invokeFailure
        )
    }
}
