import RVDomain
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

    /// A head that is a path to a host binary its basename does not name.
    @Test("a path to a host binary is that host", arguments: [
        "~/.local/share/claude/versions/2.0.14 mcp add evil -- x",
        "./node_modules/@anthropic-ai/claude-code/cli.js mcp add evil -- x",
        "node_modules/@openai/codex/bin/codex.js mcp add evil -- x",
        "/opt/homebrew/bin/claude mcp add evil -- x",
    ])
    func hostBinaryPathsCount(command: String) {
        let context = FilesystemAnalysisContext(homeDirectory: nil, mcpHostConfigGuard: MCPHostConfigGuard())
        #expect(mcpHostConfigUnmodeledWrite(command, guard: MCPHostConfigGuard(), context: context), "\(command)")
    }

    @Test func hostBinaryPathReadsStayReads() {
        let context = FilesystemAnalysisContext(homeDirectory: nil, mcpHostConfigGuard: MCPHostConfigGuard())
        let command = "~/.local/share/claude/versions/2.0.14 mcp list"
        #expect(mcpHostConfigUnmodeledWrite(command, guard: MCPHostConfigGuard(), context: context) == false)
    }

    /// Past the read budget or the nesting depth, a read counts (fail closed).
    @Test func exhaustedBudgetCounts() {
        let reads = HostTextReads()
        var counted = false
        for index in 0...HostTextReads.maxReads where reads.runsHostMCPMutation("xmcp a\(index)") {
            counted = true
        }
        #expect(counted)
        #expect(reads.exceeded)
        #expect(reads.readsDone == HostTextReads.maxReads)
    }

    /// Program text is scanned once per piece: the work is linear.
    @Test func programTextScanIsLinear() {
        let reads = HostTextReads()
        let text = (0..<1_000).map { "w\($0)" }.joined(separator: " ")
        #expect(textNamesHostMCPMutation(text, reads: reads) == false)
        #expect(reads.piecesExamined == 1_000)
        #expect(reads.exceeded == false)
    }

    /// One text over the per-text cap, or texts over the total cap, count.
    @Test func programTextPastItsCapsCounts() {
        let one = HostTextReads()
        let huge = (0...HostTextReads.maxTokenPieces).map { "w\($0)" }.joined(separator: " ")
        #expect(textNamesHostMCPMutation(huge, reads: one))
        #expect(one.exceeded)
        #expect(one.piecesExamined == 0)

        let all = HostTextReads()
        let size = HostTextReads.maxTokenPieces
        var counted = false
        for round in 0...(HostTextReads.maxPieces / size) {
            let text = (0..<size).map { "r\(round)w\($0)" }.joined(separator: " ")
            if textNamesHostMCPMutation(text, reads: all) {
                counted = true
                break
            }
        }
        #expect(counted)
        #expect(all.exceeded)
        #expect(all.piecesExamined <= HostTextReads.maxPieces)
    }

    /// The raw-word scan spends each distinct word once across its views.
    @Test func rawWordScanSpendsEachWordOnce() {
        let reads = HostTextReads()
        #expect(hostMCPTextNamesMutation("echo 'a b c'", reads: reads) == false)
        #expect(reads.piecesExamined == 3)
    }

    /// Through the guard: many distinct carried command lines exhaust the
    /// read budget, and one huge quoted argument the piece budget; both ask.
    @Test func guardAsksWhenItsBudgetRunsOut() {
        let context = FilesystemAnalysisContext(homeDirectory: nil, mcpHostConfigGuard: MCPHostConfigGuard())
        let many = "echo " + (0..<600).map { "'xmcp a\($0)'" }.joined(separator: " ") + " | sh"
        let reads = HostTextReads()
        #expect(mcpHostConfigUnmodeledWrite(many, guard: MCPHostConfigGuard(), context: context, reads: reads))
        #expect(reads.exceeded)
        #expect(reads.readsDone == HostTextReads.maxReads)

        let blob = "grep '" + (0..<100_000).map { "w\($0)" }.joined(separator: " ") + "' notes.txt"
        let pieces = HostTextReads()
        #expect(mcpHostConfigUnmodeledWrite(blob, guard: MCPHostConfigGuard(), context: context, reads: pieces))
        #expect(pieces.exceeded)
        #expect(pieces.piecesExamined <= HostTextReads.maxPieces)
    }
}
