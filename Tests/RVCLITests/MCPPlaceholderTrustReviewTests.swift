import Foundation
import RVIsolation
import RVMCP
import Testing
@testable import RVCLI

@Suite("rv mcp trust: placeholders")
struct MCPPlaceholderTrustReviewTests {
    private static let secrets = """
        {"version":1,"secrets":[
          {"name":"OPENAI_API_KEY","source":{"hostEnvironment":{"variable":"FAKE_OPENAI"}},
           "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"OPENAI_BASE_URL",
                                  "placeholderPrefix":"sk-"}}},
          {"name":"GH_TOKEN","source":{"hostEnvironment":{"variable":"FAKE_GH"}},"delivery":{"environment":{}}}
        ]}
        """

    private let configuration = MCPConfiguration(servers: [
        MCPServerDefinition(
            name: "llm", command: "/usr/bin/llm-mcp", sandbox: MCPSandboxPolicy(network: false),
            placeholders: ["OPENAI_API_KEY", "GH_TOKEN", "MISSING"])
    ])

    @Test func theReviewShowsEachPlaceholderWhatItSetsAndWhereItsValueGoes() throws {
        let loaded = try SecretsConfiguration.decode(Data(Self.secrets.utf8)).get()
        let review = MCPRun.trustReview(configuration, secrets: .success(loaded))
        let lines = review.split(separator: "\n").map(String.init)
        let openAI = try #require(lines.firstIndex(of: "    placeholder OPENAI_API_KEY"))
        #expect(lines[openAI + 1] == "      sets OPENAI_API_KEY, OPENAI_BASE_URL · real value only to api.example.com")
        let gh = try #require(lines.firstIndex(of: "    placeholder GH_TOKEN"))
        #expect(lines[gh + 1] == "      environment delivery: serve refuses this server")
        let missing = try #require(lines.firstIndex(of: "    placeholder MISSING"))
        #expect(lines[missing + 1] == "      not defined in secrets.json: serve refuses this server")
        #expect(MCPRun.trustReviewShowsEveryLiteral(configuration, review))

        let unreadable = MCPRun.trustReview(configuration, secrets: .failure(.unreadable))
        #expect(unreadable.contains("    placeholder OPENAI_API_KEY\n      secrets.json unreadable: variables and upstream unknown"))
        #expect(MCPRun.trustReviewShowsEveryLiteral(configuration, unreadable))
    }

    /// Nothing is signed unless the review names every placeholder.
    @Test func theLiteralCheckRefusesAReviewThatOmitsAPlaceholder() {
        let review = MCPRun.trustReview(configuration)
        #expect(MCPRun.trustReviewShowsEveryLiteral(configuration, review))
        let omitted = review.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0 != "    placeholder GH_TOKEN" }
            .joined(separator: "\n")
        #expect(MCPRun.trustReviewShowsEveryLiteral(configuration, omitted) == false)
    }
}
