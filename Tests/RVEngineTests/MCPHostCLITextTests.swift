import Foundation
import RVDomain
import Testing
@testable import RVEngine

/// The MCP host config guard's text reads: the stem prefilter must cover
/// every table word, and package specs normalise to the names they ship.
@Suite("MCP host CLI text reads")
struct MCPHostCLITextTests {
    /// Both prefilters pass every table word: the text-read one and the
    /// program-text one, each with its own predicate.
    @Test func everyTableWordHoldsAStem() {
        for word in hostMCPTableWords() {
            #expect(mayNameHostMCP(word), "\(word) holds no stem in hostMCPStems")
            #expect(pieceMayNameHostMCP(word), "\(word) fails the piece prefilter")
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
        "claude/versions/2.0.14 mcp add evil -- x",
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

    /// `mcp install` that some program may run counts, whatever the server
    /// and however deep the quoting: behind any wrapper, in text a runner,
    /// shell, `ssh` or substitution runs, and with no Python runner.
    @Test("mcp install that may run asks", arguments: [
        "watch 'chronic mcp install srv'",
        "su -c 'chronic mcp install srv'",
        "runuser -l me -c 'chronic mcp install srv'",
        "script -q -c 'chronic mcp install srv' /dev/null",
        "tmux new-session -d 'chronic mcp install srv'",
        "screen -dm sh -c 'chronic mcp install srv'",
        "find . -maxdepth 0 -exec sh -c 'chronic mcp install srv' ';'",
        "echo srv | xargs -n1 sh -c 'chronic mcp install \"$0\"'",
        "nsenter -t 1 -m sh -c 'chronic mcp install srv'",
        "chronic sh -c 'chronic mcp install srv'",
        "ssh localhost 'chronic mcp install srv'",
        "bash <<< 'true; chronic mcp install srv'",
        "$(echo 'chronic mcp install srv')",
        "echo 'chronic mcp install srv' > /tmp/i.sh && sh /tmp/i.sh",
        "printf '%s\\n' 'chronic mcp install srv' | sh",
        "printf '%s\\n' 'chronic mcp install srv' | at now",
        "sh -c 'echo \"chronic mcp install srv\" | sh'",
        "echo 'chronic mcp install srv' | sh",
        "echo 'npx mcp install srv' | sh",
        "echo 'chronic mcp install srv --python python3' | sh",
        "echo 'python3 -V; chronic mcp install srv' | sh",
        "echo 'chronic mcp install pkg.mod:app' | sh",
        "echo 'chronic mcp install ./servers/' | sh",
        "echo 'chronic mcp install https://example.test/s' | sh",
        "echo 'chronic mcp install s.pyz' | sh",
        "echo 'chronic mcp install s.pyw' | sh",
        "echo 'mcp install docs' | sh",
        "echo 'chronic mcp install server.py' | sh",
        // At top level, behind a wrapper with options or operands before `mcp`.
        "chronic mcp install docs",
        "op run -- mcp install srv",
        "doppler run -- mcp install srv",
        "chronic -q mcp install srv",
        "direnv exec . mcp install srv",
        "tmux new-session -d mcp install srv",
        "screen -dm mcp install srv",
        "find . -maxdepth 0 -exec mcp install srv ';'",
        // A directory option exempts `mcp` only under a build tool.
        "nsenter -t 1 -w mcp install srv",
        "chronic -C mcp install srv",
        "echo 'chronic --dir mcp install srv' | sh",
        // Only the tool's own value-taking options: a flag (`pnpm -w`, `make
        // -w`), another tool's option, or a tool not listed leaves `mcp` a
        // command that may run.
        "pnpm -w mcp install srv",
        "pnpm -F mcp install srv",
        "make -w mcp install srv",
        "bun -C mcp install srv",
        "yarn --cwd mcp install srv",
        // A top-level program named like an option is not a re-split.
        "-x -C mcp install srv",
        // `--` before the subcommand.
        "mcp -- install srv",
        "chronic mcp -- install srv",
        "echo 'mcp -- install srv' | sh",
    ])
    func runnableMCPInstallAsks(command: String) {
        #expect(judge(command), "\(command)")
    }

    /// `mcp install` that nothing runs is left alone: a plain operand of a
    /// single command that never runs its operands, on a line with no pipe,
    /// list, redirect, here-string or substitution, or `mcp` as a directory
    /// or workspace option's value.
    @Test("mcp install that nothing runs is left alone", arguments: [
        "git commit -m 'add mcp install docs'",
        "git tag -a v1 -m 'mcp install notes'",
        "gh pr create --title 'mcp install docs' --body 'run mcp install srv'",
        "grep -n 'mcp install' README.md",
        "rg 'chronic mcp install srv' docs",
        "echo 'remember to mcp install later'",
        "grep mcp install notes.txt",
        "make -C mcp install",
        "pnpm --filter mcp install",
        "npm --prefix mcp install lodash",
        "make --directory mcp install",
        "npm -w mcp install lodash",
        "npm -C mcp install lodash",
        "pnpm -C mcp install",
        "pnpm --dir mcp install",
        "bun --cwd mcp install",
        "bun -F mcp install",
        "git commit -m 'run mcp -- install srv'",
        // Escapes the tokenizer misreads, on a line nothing runs: its program
        // and subcommand are read exactly and never run their operands.
        "git commit -m \"fix \\\"mcp install\\\" docs\"",
        "grep -n \"\\\"mcp install\\\"\" notes.txt",
    ])
    func inertMCPInstallIsLeftAlone(command: String) {
        #expect(judge(command) == false, "\(command)")
    }

    /// The inert rule is the line's, not the word's: the same message on a
    /// line that runs other text, or under an unknown program, asks.
    @Test("mcp install text off an inert line asks", arguments: [
        "cd x && git commit -m 'add mcp install docs'",
        "git commit -m 'add mcp install docs' | sh",
        "rg --pre ./x 'chronic mcp install srv' docs",
        "git -c core.editor=vi commit -m 'chronic mcp install srv'",
        "notes add 'chronic mcp install srv'",
    ])
    func mcpInstallOffAnInertLineAsks(command: String) {
        #expect(judge(command), "\(command)")
    }

    /// Text the tokenizer splits or quotes unlike a shell (a backslash before
    /// a quote or a blank, `\'` in `$'…'`, zsh `=(…)`) that may name a host
    /// asks, unless the line is inert. A backslash in an inert line's program
    /// or subcommand, or any parenthesis, makes it not inert.
    @Test("text the tokenizer cannot follow asks", arguments: [
        "watch \"sh -c \\\"claude mcp add evil -- x\\\"\"",
        "watch 'sh -c '\\''claude mcp add evil -- x'\\'''",
        "watch claude\\ mcp\\ add\\ evil",
        "echo $'claude mcp add \\'x\\'' | sh",
        "cat =(claude mcp add x)",
        "grep -n x =(mcp install srv)",
        "=claude mcp add evil -- x",
        "git commit -m \"fix \\\"mcp install\\\" docs\" && true",
        "git c\\ommit -m 'mcp install srv'",
    ])
    func unfollowableTextAsks(command: String) {
        #expect(judge(command), "\(command)")
    }

    /// The `'\''` nesting the tokenizer cannot follow asks as unfollowable
    /// text, whatever its depth: the tokenizer keeps the backslash, so each
    /// level would split into words and never reach the depth cap.
    @Test func misquotedNestingAsksAsUnfollowable() {
        var command = "watch xmcp end"
        for _ in 0..<(HostTextReads.maxDepth + 2) {
            command = "watch '" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var reads = HostTextReads()
        #expect(judge(command, &reads))
        #expect(reads.unfollowable)
        #expect(hasUnfollowableShellText("watch 'a '\\''b'\\'''"))
        #expect(hasUnfollowableShellText("echo \"a \\\"b\\\"\""))
        #expect(hasUnfollowableShellText("a\\ b"))
        #expect(hasUnfollowableShellText("echo $'a \\'b'"))
        #expect(hasUnfollowableShellText("cat =(true)"))
        #expect(hasUnfollowableShellText("echo 'a\\ b' \"a\\$b\" $'a\\x27b' a\\\nb") == false)
    }

    /// Past the read budget or the nesting depth, a read counts (fail closed).
    @Test func exhaustedBudgetCounts() {
        var reads = HostTextReads()
        var counted = false
        for index in 0...HostTextReads.maxReads {
            if reads.runsHostMCPMutation("xmcp a\(index)") { counted = true }
        }
        #expect(counted)
        #expect(reads.exceeded)
        #expect(reads.readsDone == HostTextReads.maxReads)
    }

    /// Program text that holds a stem spends one piece per piece. (This
    /// counts pieces charged, not the work done per piece.)
    @Test func programTextSpendsOnePiecePerPiece() {
        var reads = HostTextReads()
        let text = ((0..<999).map { "w\($0)" } + ["config"]).joined(separator: " ")
        #expect(textNamesHostMCPMutation(text, reads: &reads) == false)
        #expect(reads.piecesExamined == 1_000)
        #expect(reads.exceeded == false)
    }

    /// Text no piece of which holds a stem cannot name a host mutation: it
    /// spends nothing and is never refused for its size.
    @Test func stemFreeTextSpendsNothing() {
        var reads = HostTextReads()
        let text = (0..<5_000).map { "w\($0)" }.joined(separator: " ")
        #expect(textNamesHostMCPMutation(text, reads: &reads) == false)
        #expect(reads.piecesExamined == 0)
        #expect(reads.exceeded == false)
        // A stem reached only by decoding a package spec still counts.
        #expect(textNamesHostMCPMutation(text + " install-%6dcp", reads: &reads))
    }

    /// One text over the per-text cap, or texts over the total cap, count.
    @Test func programTextPastItsCapsCounts() {
        var one = HostTextReads()
        let huge = ((0..<HostTextReads.maxTokenPieces).map { "w\($0)" } + ["config"]).joined(separator: " ")
        #expect(textNamesHostMCPMutation(huge, reads: &one))
        #expect(one.exceeded)
        #expect(one.piecesExamined == 0)

        var all = HostTextReads()
        let size = HostTextReads.maxTokenPieces
        var counted = false
        for round in 0...(HostTextReads.maxPieces / size) {
            let text = ((0..<(size - 1)).map { "r\(round)w\($0)" } + ["config"]).joined(separator: " ")
            if textNamesHostMCPMutation(text, reads: &all) {
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
        var reads = HostTextReads()
        #expect(hostMCPTextNamesMutation("echo 'a b config'", reads: &reads) == false)
        #expect(reads.piecesExamined == 3)
    }

    /// Through the guard: many distinct carried command lines exhaust the
    /// read budget and ask.
    @Test func guardAsksWhenItsBudgetRunsOut() {
        let many = "echo " + (0..<600).map { "'xmcp a\($0)'" }.joined(separator: " ") + " | sh"
        var reads = HostTextReads()
        #expect(judge(many, &reads))
        #expect(reads.exceeded)
        #expect(reads.readsDone == HostTextReads.maxReads)
    }

    /// Through the guard: quoting nested past `maxDepth` asks, whatever
    /// sits at the bottom, a real host mutation included. Each level is an
    /// ANSI-C string the tokenizer follows exactly (`\x5c`, `\x27` and
    /// `\x20` for the backslash, quote and blank of the level inside).
    @Test("quoting nested past the depth cap asks", arguments: ["watch xmcp end", "claude mcp add x -- y"])
    func guardAsksPastTheDepthCap(bottom: String) {
        var command = bottom
        for _ in 0..<(HostTextReads.maxDepth + 2) {
            let escaped = command
                .replacingOccurrences(of: "\\", with: "\\x5c")
                .replacingOccurrences(of: "'", with: "\\x27")
                .replacingOccurrences(of: " ", with: "\\x20")
            command = "watch $'" + escaped + "'"
        }
        var reads = HostTextReads()
        #expect(judge(command, &reads), "\(command)")
        #expect(reads.depthExceeded, "\(command)")
        #expect(reads.unfollowable == false, "\(command)")
        #expect(reads.readsDone < HostTextReads.maxReads, "\(command)")
    }

    /// Through the guard, long text is judged by what it names, not its
    /// size: past the piece caps, text with no stem stays allowed and text
    /// that names a host mutation, plain or encoded, still asks.
    @Test func guardJudgesLongTextByWhatItNames() {
        let words = (0..<5_000).map { "w\($0)" }
        let line = "claude mcp add x -- y"
        var plain = HostTextReads()
        #expect(judge("grep '" + words.joined(separator: " ") + "' notes.txt", &plain) == false)
        #expect(plain.piecesExamined == 0)
        let middle = Array(words[..<2_500]) + [line] + Array(words[2_500...])
        #expect(judge("grep '" + middle.joined(separator: " ") + "' notes.txt"))
        #expect(judge("grep '" + (words + [line]).joined(separator: " ") + "' notes.txt"))
        let encoded = (words + ["\\x63laude \\x6dcp add x"]).joined(separator: " ")
        #expect(judge("grep $'" + encoded + "' notes.txt"))

        // 20 words of 3,500 pieces each: 70,000 in all, past `maxPieces`.
        let wide = (0..<20).map { word in (0..<3_500).map { "r\(word)w\($0)" } }
        var stemFree = HostTextReads()
        let unnamed = wide.map { $0.joined(separator: ",") }
        #expect(judge("grep " + unnamed.joined(separator: " ") + " notes.txt", &stemFree) == false)
        #expect(stemFree.piecesExamined == 0)
        var stemmed = HostTextReads()
        let named = wide.map { (Array($0.dropLast()) + ["config"]).joined(separator: ",") }
        #expect(judge("grep " + named.joined(separator: " ") + " notes.txt", &stemmed))
        #expect(stemmed.exceeded)
    }
}

/// The guard's verdict on `command`: true asks.
private func judge(_ command: String) -> Bool {
    var reads = HostTextReads()
    return judge(command, &reads)
}

/// The guard's verdict on `command`, spending `reads`: true asks.
private func judge(_ command: String, _ reads: inout HostTextReads) -> Bool {
    let context = FilesystemAnalysisContext(homeDirectory: nil, mcpHostConfigGuard: MCPHostConfigGuard())
    return mcpHostConfigUnmodeledWrite(command, guard: MCPHostConfigGuard(), context: context, reads: &reads)
}
