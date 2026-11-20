import Foundation
import RVHistory
import Testing
@testable import RVIsolation

/// Every recorded egress reason and every secret gateway refusal has its
/// own OCSF reason code: a new case that lands in an `*-other` fallback
/// fails here until `AuditReasonCode` and the docs table name it.
@Suite("AuditReasonCode coverage")
struct AuditReasonCodeCoverageTests {
    @Test func everyEgressDenialReasonHasItsOwnCode() {
        for reason in EgressDenialReason.allCases {
            let code = AuditReasonCode.egress(reason: reason.rawValue)
            #expect(code?.rawValue == "rv.egress.\(reason.rawValue)", "no reason code for egress \(reason.rawValue)")
        }
    }

    @Test func everyGatewayRefusalHasItsOwnCode() {
        var seen: Set<AuditReasonCode> = []
        for refusal in GatewayRefusal.allCases {
            let code = AuditReasonCode.secret(refusal: refusal.code)
            #expect(code != nil, "no reason code for gateway refusal \(refusal.code)")
            if let code { seen.insert(code) }
        }
        #expect(seen.count == GatewayRefusal.allCases.count)
    }
}
