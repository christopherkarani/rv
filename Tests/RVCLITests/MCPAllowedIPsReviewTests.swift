import Foundation
import RVDomain
import RVMCP
import Testing
@testable import RVCLI

/// `sandbox.allowed_ips` is visible in the owner-authenticated
/// `rv mcp trust` review, marked as a loosening, and the review gate
/// refuses to sign a review that omits a range.
@Suite("rv mcp trust allowed_ips")
struct MCPAllowedIPsReviewTests {
    static func configuration() throws -> MCPConfiguration {
        let ranges = try EgressAllowedIPs(parsing: ["10.0.5.0/24", "fd12:3456:789a::/48"])
        return MCPConfiguration(servers: [
            MCPServerDefinition(
                name: "staging", command: "staging-mcp",
                sandbox: MCPSandboxPolicy(
                    network: false, hosts: ["staging.corp.lan", "api.example.com"],
                    allowedIPs: ["staging.corp.lan": ranges]))
        ])
    }

    @Test func trustReviewListsEveryRangeAsALoosening() throws {
        let configuration = try Self.configuration()
        let review = MCPRun.trustReview(configuration)
        #expect(review.contains("    allowed_ips staging.corp.lan 10.0.5.0/24"), "\(review)")
        #expect(review.contains("    allowed_ips staging.corp.lan fd12:3456:789a::/48"), "\(review)")
        #expect(review.contains("private networks for staging.corp.lan (loosens public-only)"), "\(review)")
        #expect(review.contains("allowed_ips api.example.com") == false)
        #expect(MCPRun.trustReviewShowsEveryLiteral(configuration, review))
    }

    @Test func reviewThatOmitsARangeIsNotSigned() throws {
        let configuration = try Self.configuration()
        let review = MCPRun.trustReview(configuration)
            .replacingOccurrences(of: "    allowed_ips staging.corp.lan 10.0.5.0/24\n", with: "")
        #expect(MCPRun.trustReviewShowsEveryLiteral(configuration, review) == false)
    }
}
