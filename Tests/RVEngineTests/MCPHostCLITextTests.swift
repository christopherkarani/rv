import Testing
@testable import RVEngine

/// The MCP host config guard's text reads: the stem prefilter must cover
/// every table word, and package specs normalise to the names they ship.
@Suite("MCP host CLI text reads")
struct MCPHostCLITextTests {
    @Test func everyTableWordHoldsAStem() {
        for word in hostMCPTableWords() {
            #expect(mayNameHostMCP(word), "\(word) holds no stem in hostMCPStems")
        }
    }

    @Test("the prefilter sees through quoting and encoding", arguments: [
        "c'l'aude", "C\"L\"AUDE", "cla\\\nude", "\\x63laude", "%63laude-code", "\\\\x6dcp",
    ])
    func prefilterDecodes(text: String) {
        #expect(mayNameHostMCP(text), "\(text)")
    }

    @Test func prefilterSkipsOrdinaryText() {
        #expect(mayNameHostMCP("npm test") == false)
        #expect(mayNameHostMCP("fix the failing test in $FILE") == false)
    }

    @Test("package specs name the package they ship", arguments: [
        ("foo@npm:install-mcp", "install-mcp"),
        ("foo@npm:@smithery/cli", "@smithery/cli"),
        ("https://registry.npmjs.org/@smithery/cli/-/cli-1.2.3.tgz", "@smithery/cli"),
        ("github:smithery-ai/cli", "smithery-ai/cli"),
        ("npm:install-mcp/dist/index.js", "install-mcp"),
        ("--package=install-mcp", "install-mcp"),
        ("nixpkgs#claude-code", "claude-code"),
        ("https://registry.npmjs.org/@openai%2fcodex/-/codex-0.46.0.tgz", "@openai/codex"),
        ("mcp[cli]@1.6", "mcp"),
        ("fastmcp@2", "fastmcp"),
    ])
    func packageSpecs(spec: String, name: String) {
        #expect(packageNames(spec).contains(name), "\(spec): \(packageNames(spec))")
    }

    @Test func unrelatedSpecsNameNoTablePackage() {
        #expect(packageNames("github:owner/some-tool").contains("install-mcp") == false)
        #expect(packageNames("tools/gemini-cli-docs").contains("gemini-cli") == false)
        #expect(packageNames("add-mcp-support").contains("add-mcp") == false)
    }

    /// Past the read budget or the nesting depth, a read counts (fail closed).
    @Test func exhaustedBudgetCounts() {
        let reads = HostTextReads()
        var counted = false
        for index in 0...HostTextReads.maxReads where reads.runsHostMCPMutation("xmcp a\(index)") {
            counted = true
        }
        #expect(counted)
    }
}
