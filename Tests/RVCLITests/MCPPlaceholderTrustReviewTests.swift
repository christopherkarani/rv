import Foundation
import RVIsolation
import RVMCP
import Testing
@testable import RVCLI

@Suite("rv mcp trust: placeholders")
struct MCPPlaceholderTrustReviewTests {
    private static let secrets = """
        {"version":1,"secrets":[
          {"name":"OPENAI_API_KEY","source":{"keychain":{"service":"rv.secrets","account":"OPENAI_API_KEY"}},
           "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"OPENAI_BASE_URL",
                                  "placeholderPrefix":"sk-"}}},
          {"name":"HOST_SOURCED","source":{"hostEnvironment":{"variable":"FAKE_OPENAI"}},
           "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"HOST_BASE_URL"}}},
          {"name":"GH_TOKEN","source":{"keychain":{"service":"rv.secrets","account":"GH_TOKEN"}},
           "delivery":{"environment":{}}}
        ]}
        """

    private static func loaded() throws -> SecretsConfiguration {
        try SecretsConfiguration.decode(Data(secrets.utf8)).get()
    }

    private let configuration = MCPConfiguration(servers: [
        MCPServerDefinition(
            name: "llm", command: "/usr/bin/llm-mcp", sandbox: MCPSandboxPolicy(network: false),
            placeholders: ["OPENAI_API_KEY", "HOST_SOURCED", "GH_TOKEN", "MISSING"])
    ])

    @Test func theReviewShowsEachPlaceholderWhatItSetsAndWhereItsValueGoes() throws {
        let review = MCPRun.trustReview(configuration, secrets: .success(try Self.loaded()))
        let lines = review.split(separator: "\n").map(String.init)
        let openAI = try #require(lines.firstIndex(of: "    placeholder OPENAI_API_KEY"))
        #expect(lines[openAI + 1] == "      sets OPENAI_API_KEY, OPENAI_BASE_URL · real value only to https://api.example.com")
        let host = try #require(lines.firstIndex(of: "    placeholder HOST_SOURCED"))
        #expect(lines[host + 1] == "      read from rv's own environment: serve refuses this server")
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

    /// The signature covers mcp.json, not secrets.json: a review that could
    /// not say where a placeholder's value goes signs nothing.
    @Test func trustSignsNothingWhileAPlaceholderIsUnknown() throws {
        let defined = MCPConfiguration(servers: [
            MCPServerDefinition(
                name: "llm", command: "/usr/bin/llm-mcp", sandbox: MCPSandboxPolicy(network: false),
                placeholders: ["OPENAI_API_KEY"])
        ])
        let secrets = try Self.loaded()
        #expect(MCPRun.placeholderSigningRefusal(defined, secrets: .success(secrets)) == nil)
        #expect(MCPRun.placeholderSigningRefusal(configuration, secrets: .success(secrets))
            == "secrets.json does not define placeholder MISSING of llm; nothing signed")
        #expect(MCPRun.placeholderSigningRefusal(defined, secrets: .failure(.unreadable))
            == "secrets.json cannot be read, so the review cannot say where llm's placeholders go; nothing signed")
        let plain = MCPConfiguration(servers: [MCPServerDefinition(name: "fs", command: "fs-mcp")])
        #expect(MCPRun.placeholderSigningRefusal(plain, secrets: .failure(.unreadable)) == nil)
    }

    /// What serve tells stderr once a server is running bound: from the
    /// definitions its lease staged, not from serve's own read.
    @Test func serveNamesEachBindingItMade() throws {
        let definitions = try Self.loaded().secrets.filter { $0.name == "OPENAI_API_KEY" }
        #expect(MCPRun.placeholderBindingLog(server: "llm", definitions: definitions) == [
            "MCP server llm: placeholder OPENAI_API_KEY sets OPENAI_API_KEY, OPENAI_BASE_URL · "
                + "real value only to https://api.example.com"
        ])
        #expect(MCPRun.placeholderBindingLog(server: "llm\u{1B}[2J", definitions: definitions).first?
            .hasPrefix("MCP server llm\\u{001B}[2J: ") == true)
    }
}
