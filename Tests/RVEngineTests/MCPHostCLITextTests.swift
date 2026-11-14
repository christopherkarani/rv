import Foundation
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

    /// `mcp install` in prose that names no host is left alone; run, or
    /// carried as a command line of its own, it still counts.
    @Test func mcpInstallInProseIsNotRun() {
        let context = FilesystemAnalysisContext(homeDirectory: nil, mcpHostConfigGuard: MCPHostConfigGuard())
        let judge = { (command: String) in
            mcpHostConfigUnmodeledWrite(command, guard: MCPHostConfigGuard(), context: context)
        }
        #expect(judge("git commit -m 'add mcp install docs'") == false)
        #expect(judge("chronic mcp install docs"))
        #expect(judge("echo 'mcp install docs' | sh"))
        #expect(judge("echo 'chronic mcp install server.py' | sh"))
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

    /// Program text that holds a stem spends one piece per piece. (This
    /// counts pieces charged, not the work done per piece.)
    @Test func programTextSpendsOnePiecePerPiece() {
        let reads = HostTextReads()
        let text = ((0..<999).map { "w\($0)" } + ["config"]).joined(separator: " ")
        #expect(textNamesHostMCPMutation(text, reads: reads) == false)
        #expect(reads.piecesExamined == 1_000)
        #expect(reads.exceeded == false)
    }

    /// Text no piece of which holds a stem cannot name a host mutation: it
    /// spends nothing and is never refused for its size.
    @Test func stemFreeTextSpendsNothing() {
        let reads = HostTextReads()
        let text = (0..<5_000).map { "w\($0)" }.joined(separator: " ")
        #expect(textNamesHostMCPMutation(text, reads: reads) == false)
        #expect(reads.piecesExamined == 0)
        #expect(reads.exceeded == false)
        // A stem reached only by decoding a package spec still counts.
        #expect(textNamesHostMCPMutation(text + " install-%6dcp", reads: reads))
    }

    /// One text over the per-text cap, or texts over the total cap, count.
    @Test func programTextPastItsCapsCounts() {
        let one = HostTextReads()
        let huge = ((0..<HostTextReads.maxTokenPieces).map { "w\($0)" } + ["config"]).joined(separator: " ")
        #expect(textNamesHostMCPMutation(huge, reads: one))
        #expect(one.exceeded)
        #expect(one.piecesExamined == 0)

        let all = HostTextReads()
        let size = HostTextReads.maxTokenPieces
        var counted = false
        for round in 0...(HostTextReads.maxPieces / size) {
            let text = ((0..<(size - 1)).map { "r\(round)w\($0)" } + ["config"]).joined(separator: " ")
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
        #expect(hostMCPTextNamesMutation("echo 'a b config'", reads: reads) == false)
        #expect(reads.piecesExamined == 3)
    }

    /// Through the guard: many distinct carried command lines exhaust the
    /// read budget and ask.
    @Test func guardAsksWhenItsBudgetRunsOut() {
        let many = "echo " + (0..<600).map { "'xmcp a\($0)'" }.joined(separator: " ") + " | sh"
        let reads = HostTextReads()
        #expect(judge(many, reads))
        #expect(reads.exceeded)
        #expect(reads.readsDone == HostTextReads.maxReads)
    }

    /// Through the guard: quoting nested past `maxDepth` asks.
    @Test func guardAsksPastTheDepthCap() {
        var command = "watch xmcp end"
        for _ in 0..<(HostTextReads.maxDepth + 2) {
            command = "watch '" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let reads = HostTextReads()
        #expect(judge(command, reads))
        #expect(reads.depthExceeded)
        #expect(reads.readsDone < HostTextReads.maxReads)
    }

    /// Through the guard, long text is judged by what it names, not its
    /// size: past the piece caps, text with no stem stays allowed and text
    /// that names a host mutation, plain or encoded, still asks.
    @Test func guardJudgesLongTextByWhatItNames() {
        let words = (0..<5_000).map { "w\($0)" }
        let line = "claude mcp add x -- y"
        let plain = HostTextReads()
        #expect(judge("grep '" + words.joined(separator: " ") + "' notes.txt", plain) == false)
        #expect(plain.piecesExamined == 0)
        let middle = Array(words[..<2_500]) + [line] + Array(words[2_500...])
        #expect(judge("grep '" + middle.joined(separator: " ") + "' notes.txt"))
        #expect(judge("grep '" + (words + [line]).joined(separator: " ") + "' notes.txt"))
        let encoded = (words + ["\\x63laude \\x6dcp add x"]).joined(separator: " ")
        #expect(judge("grep $'" + encoded + "' notes.txt"))

        // 20 words of 3,500 pieces each: 70,000 in all, past `maxPieces`.
        let wide = (0..<20).map { word in (0..<3_500).map { "r\(word)w\($0)" } }
        let stemFree = HostTextReads()
        let unnamed = wide.map { $0.joined(separator: ",") }
        #expect(judge("grep " + unnamed.joined(separator: " ") + " notes.txt", stemFree) == false)
        #expect(stemFree.piecesExamined == 0)
        let stemmed = HostTextReads()
        let named = wide.map { (Array($0.dropLast()) + ["config"]).joined(separator: ",") }
        #expect(judge("grep " + named.joined(separator: " ") + " notes.txt", stemmed))
        #expect(stemmed.exceeded)
    }
}

/// The guard's verdict on `command`: true asks.
private func judge(_ command: String, _ reads: HostTextReads = HostTextReads()) -> Bool {
    let context = FilesystemAnalysisContext(homeDirectory: nil, mcpHostConfigGuard: MCPHostConfigGuard())
    return mcpHostConfigUnmodeledWrite(command, guard: MCPHostConfigGuard(), context: context, reads: reads)
}
