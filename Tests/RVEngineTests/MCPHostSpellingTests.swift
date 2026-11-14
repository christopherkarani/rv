import Foundation
import RVDomain
import Testing
@testable import RVEngine

/// A command the guard must still catch when one word is spelled a way a
/// POSIX or zsh shell resolves to the same word (an empty quote, a backslash,
/// an ANSI-C escape, a brace or glob, a variable or substitution), or the
/// words are separated by something other than a plain space. `knownIssue`
/// marks a residual the guard does not yet catch (also in the README limits).
struct SpellCase: CustomStringConvertible, Sendable {
    let command: String
    let knownIssue: String?
    var description: String { knownIssue == nil ? command : command + "  [known: \(knownIssue!)]" }
}

/// Spelling transforms and dynamic resolution are judged by what a word can
/// produce, not by its literal text. The canonical payloads are a real host
/// mutation (`claude mcp add`) and the `mcp install` installer behind an
/// unknown wrapper; each must still ask under every spelling the shell
/// resolves to it, bare and behind one wrapper.
/// Two hex digits of a lowercase letter (`c` -> `63`); letters are one byte
/// above 0x60, so always two digits.
private func hex(_ c: Character) -> String { String(Int(c.asciiValue ?? 63), radix: 16) }
/// Four hex digits, for `\uXXXX`.
private func hex4(_ c: Character) -> String {
    let h = hex(c)
    return String(repeating: "0", count: max(0, 4 - h.count)) + h
}
/// Up to three octal digits, for `\NNN`.
private func octal(_ c: Character) -> String { String(Int(c.asciiValue ?? 63), radix: 8) }
/// The letter one code point below `c`, for a `{d..e}` range.
private func prior(_ c: Character) -> Character { Character(UnicodeScalar((c.asciiValue ?? 63) - 1)) }
/// Single-quote a line for a wrapper that re-runs it as a string.
private func shQuoted(_ line: String) -> String {
    "'" + line.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
/// The installer's host word (`mcp`) given as a value rv cannot read — a
/// documented residual: asking there would fire on every `$PM install`. A
/// dynamic subcommand after a literal `mcp` asks.
private func installerDynamicIsAResidual(payload: Int, position: Int, dynamic: Bool) -> Bool {
    payload == 1 && dynamic && position == 1
}

@Suite("MCP host spelling and dynamic resolution")
struct MCPHostSpellingTests {
    /// `claude mcp add evil -- x` and `chronic mcp install srv`, by word.
    static let payloads: [[String]] = [
        ["claude", "mcp", "add", "evil", "--", "x"],
        ["chronic", "mcp", "install", "srv"],
    ]

    /// A one-word rewrite the shell resolves back to `word`; nil when it does
    /// not apply (too short). `dynamic` transforms stand for a value rv cannot
    /// read.
    static let transforms: [(name: String, dynamic: Bool, apply: @Sendable (String) -> String?)] = [
        ("single-whole", false, { "'\($0)'" }),
        ("double-whole", false, { "\"\($0)\"" }),
        ("single-first", false, { w in w.count >= 2 ? "'\(w.first!)'\(w.dropFirst())" : nil }),
        ("empty-single", false, { w in w.count >= 2 ? "\(w.first!)''\(w.dropFirst())" : nil }),
        ("empty-double", false, { w in w.count >= 2 ? "\(w.first!)\"\"\(w.dropFirst())" : nil }),
        ("backslash-letter", false, { w in w.count >= 2 ? "\(w.first!)\\\(w.dropFirst())" : nil }),
        ("line-continuation", false, { w in w.count >= 2 ? "\(w.first!)\\\n\(w.dropFirst())" : nil }),
        ("ansi-hex", false, { w in w.count >= 2 ? "$'\\x\(hex(w.first!))'\(w.dropFirst())" : nil }),
        ("ansi-octal", false, { w in w.count >= 2 ? "$'\\\(octal(w.first!))'\(w.dropFirst())" : nil }),
        ("ansi-unicode", false, { w in w.count >= 2 ? "$'\\u\(hex4(w.first!))'\(w.dropFirst())" : nil }),
        ("ansi-whole", false, { "$'\($0)'" }),
        ("brace-alt", false, { w in w.count >= 3 ? "{\(w),zzqx}" : nil }),
        ("brace-range", false, { w in w.count >= 3 ? "\(w.dropLast()){\(prior(w.last!))..\(w.last!)}" : nil }),
        ("glob-question", false, { w in w.count >= 3 ? "\(w.first!)?\(w.dropFirst(2))" : nil }),
        ("glob-class", false, { w in w.count >= 3 ? "\(w.first!)[\(Array(w)[1])]\(w.dropFirst(2))" : nil }),
        ("glob-star", false, { w in w.count >= 3 ? "\(w.first!)*\(w.last!)" : nil }),
        ("var", true, { _ in "$HOSTSPELLW" }),
        ("var-default", true, { "${HOSTSPELLW:-\($0)}" }),
        ("cmdsub", true, { "$(printf %s \($0))" }),
        ("backtick", true, { "`printf %s \($0)`" }),
    ]

    static let wrappers: [@Sendable (String) -> String] = [
        { $0 },
        { "sh -c \(shQuoted($0))" },
        { "watch \(shQuoted($0))" },
        { "echo \(shQuoted($0)) | sh" },
        { "stdbuf -o0 \($0)" },
    ]

    static let spellingCases: [SpellCase] = {
        var cases: [SpellCase] = []
        for (payloadIndex, payload) in payloads.enumerated() {
            for position in payload.indices {
                for transform in transforms {
                    guard let spelled = transform.apply(payload[position]) else { continue }
                    var words = payload
                    words[position] = spelled
                    let line = words.joined(separator: " ")
                    // A dynamic value at the installer's group or subcommand
                    // is a residual the guard cannot resolve, bare or wrapped:
                    // every wrapper re-runs the same unresolved words.
                    let known = installerDynamicIsAResidual(
                        payload: payloadIndex, position: position, dynamic: transform.dynamic)
                        ? "mcp install installer: a value rv cannot read at the host position"
                        : nil
                    for wrap in wrappers {
                        cases.append(SpellCase(command: wrap(line), knownIssue: known))
                    }
                }
            }
            // Separators other than a plain space, applied across the line.
            for joiner in ["\t", "   "] {
                cases.append(SpellCase(command: payload.joined(separator: joiner), knownIssue: nil))
            }
            // `$IFS` splits words where rv's tokenizer sees none (`$IFS''`
            // ends the name without adding a word), bare and wrapped.
            for joiner in ["$IFS ", "${IFS}", "$IFS''"] {
                let line = payload.joined(separator: joiner)
                for wrap in wrappers {
                    cases.append(SpellCase(command: wrap(line), knownIssue: nil))
                }
            }
        }
        return cases
    }()

    /// A compact JSON body longer than `SpellingBudget.maxWordLength`.
    static let longJSONCurl = "curl -d '{" + (0..<40).map { "\"k\($0)\":\($0)" }.joined(separator: ",")
        + "}' https://api.example.com/x"

    @Test("every spelling of a host mutation still asks", arguments: spellingCases)
    func spellingStillAsks(_ item: SpellCase) {
        if let reason = item.knownIssue {
            withKnownIssue("\(reason)") {
                #expect(judgeSpelling(item.command), "\(item.command)")
            }
        } else {
            #expect(judgeSpelling(item.command), "\(item.command)")
        }
    }

    /// The same transforms on commands that name no host and no `mcp` never
    /// fire the guard: guard-on reads exactly like guard-off.
    static let lookAlikes: [[String]] = [
        ["git", "commit", "-m", "update-docs"],
        ["ls", "-la", "src"],
        ["npm", "install", "lodash"],
        ["make", "install"],
    ]

    static let mirrorCases: [SpellCase] = {
        var cases: [SpellCase] = []
        for payload in lookAlikes {
            for position in payload.indices {
                for transform in transforms {
                    guard let spelled = transform.apply(payload[position]) else { continue }
                    var words = payload
                    words[position] = spelled
                    cases.append(SpellCase(command: words.joined(separator: " "), knownIssue: nil))
                }
            }
        }
        return cases
    }()

    @Test("spellings of a look-alike never fire the guard", arguments: mirrorCases)
    func lookAlikeNeverAsks(_ item: SpellCase) {
        #expect(judgeSpelling(item.command) == false, "\(item.command)")
    }

    /// Carried text with no stem whose glob or brace word may expand to a
    /// table word is read, not skipped by the prefilter.
    @Test("carried text spelling a host word with no stem asks", arguments: [
        "watch 'chronic m?p install srv'", "watch 'chronic m[c]p install srv'",
        "watch 'chronic m*p install srv'", "watch 'chronic mc{o..p} install srv'",
        "echo 'chronic m?p install srv' | sh", "echo 'chronic m[c]p install srv' | sh",
        "echo 'chronic m*p install srv' | sh", "echo 'chronic mc{o..p} install srv' | sh",
    ])
    func carriedSpellingAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    @Test("the prefilter passes a glob or brace word that may be a table word")
    func prefilterReadsSpellings() {
        for text in ["chronic m?p install srv", "chronic m[c]p install srv", "chronic m*p install srv",
                     "chronic mc{o..p} install srv", "stdbuf src/clau?e x", "chronic m?p${IFS}install"]
        {
            #expect(mayNameHostMCP(text), "\(text)")
        }
        for text in ["ls src/*.swift", "tr '[:upper:]' '[:lower:]'", "cp {a,b}.txt dst/", "touch f{1..100}"] {
            #expect(mayNameHostMCP(text) == false, "\(text)")
        }
    }

    /// A brace word the shell splits into several words, a POSIX class, and
    /// a word the shell expands to nothing before the subcommand.
    @Test("a spelling the shell splits or classes still asks", arguments: [
        "{claude,mcp} add evil -- x", "stdbuf -o0 {claude,mcp} add evil -- x", "chronic {mcp,install} srv",
        "chronic mcp {,} install srv",
        "stdbuf -o0 clau[[:alpha:]]e mcp add evil -- x", "claude m[[:alpha:]]p add evil -- x",
        "stdbuf -o0 {code,--add-mcp} x", "chronic {mcp,$SUB} srv",
    ])
    func splitSpellingAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    /// Spellings count only where the word may run: a glob operand of a
    /// command that never runs its operands, text such a command carries,
    /// and a quoted word holding a blank are what they were before
    /// spellings were resolved.
    @Test("a spelling that cannot run is only its own text", arguments: [
        "grep -rn claude *", "rg codex *", "grep -rn claude * | head", "rg -l codex * | wc -l",
        "grep fastmcp $X", "git commit -m 'claude m?p add'", "grep -rn 'chronic m?p install' src | head",
        "claude -p \"explain function f() { ... }\"", "codex exec \"fix {x} in ../src\"",
        "claude -p 'rename {a,b}.ts to ../c'", "tr '[:upper:]' '[:lower:]'",
        "echo x | tr '[:upper:]' '[:lower:]'", "touch f{1..100}", "mkdir -p src/{a,b,c}", "ls *",
        "np{l..m} install lodash", "ma{j..k}e install",
    ])
    func unrunnableSpellingAllows(_ command: String) {
        #expect(judgeSpelling(command) == false, "\(command)")
    }

    /// A program not known to leave its operands alone may run them: these
    /// ask as their literal forms (`ls mcp install`) always have. So does a
    /// command that leaves them alone when a wrapper or a path runs it, or
    /// git with an option before its subcommand; and its literal words and
    /// carried text are read as before.
    @Test("a spelled operand of a program that may run still asks", arguments: [
        "chronic mcp *", "tar czf out.tgz mcp $EXTRA", "stdbuf -o0 ls mcp $DIR", "/bin/ls mcp $DIR",
        "git -C . add mcp *", "ls mcp install", "ls 'chronic mcp install x'",
        "git add mcp install",
    ])
    func runnableSpelledOperandAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    /// `ls`, `cp`, `mv`, `rm`, `mkdir`, `touch`, `cat` and `git
    /// add|status|diff|rm`, by their plain names, never run an operand: its
    /// brace, glob and dynamic spellings do not count.
    @Test("a spelled operand of a command that leaves its operands alone allows", arguments: [
        "ls mcp *", "git add mcp *", "ls mcp $DIR", "cp -r packages/mcp \"$DEST\"", "rm -rf build/mcp $TMP",
        "mv mcp $BACKUP", "touch {a..z}{0..9}", "mkdir -p {a..h}/{1..9}", "git status mcp *",
        "git diff mcp $REF", "cat mcp/{a,b}.md", "sudo rm -rf build/mcp $TMP",
    ])
    func operandsLeftAloneAllow(_ command: String) {
        #expect(judgeSpelling(command) == false, "\(command)")
    }

    /// Where the line may define or redefine a command (a function, an alias,
    /// a `PATH` change, a sourced file, `eval`, a dynamic program), a plain
    /// `ls` may run its operands, so their spellings count again.
    @Test("the operand list backs off where the line may define commands", arguments: [
        "ls() { \"$@\"; }; ls mcp $X", "function ls { eval \"$@\"; }; ls mcp $X", "alias ls=eval; ls mcp $X",
        "PATH=./bin:$PATH ls mcp $X", ". ./lib.sh; ls mcp $X", "source ./lib.sh && cat mcp $X",
        "eval \"$DEF\"; ls mcp $X", "$INIT; ls mcp $X", "BASH_ALIASES[ls]=eval; ls mcp $X",
        "trap \"$T\" DEBUG; ls mcp $X",
    ])
    func redefinedOperandListAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    @Test("the operand list holds on a line that defines nothing", arguments: [
        "ls mcp $X", "ls -la mcp $X", "cd \"$DIR\" && ls mcp $X",
    ])
    func plainOperandListAllows(_ command: String) {
        #expect(judgeSpelling(command) == false, "\(command)")
    }

    /// `find` runs only the words of its `-exec`, `-execdir`, `-ok` and
    /// `-okdir` clauses; `xargs` and `watch` take their options' values
    /// before the program. A dynamic word in a runs position still asks;
    /// one of those operands does not, by its plain name on a line that
    /// defines nothing.
    @Test("a dynamic word a runner really runs still asks", arguments: [
        "find \"$DIR\" -exec $c mcp add evil -- x \\;", "find . -name x -exec claude mcp add evil -- x \\;",
        "find . -exec stdbuf -o0 $c mcp add evil -- x \\;", "find . -okdir $c mcp add evil -- x {} +",
        "find . -exec echo {} \\; -exec $c mcp add evil -- x \\;", "find . -exec $c {} + mcp add evil -- x",
        "./find . \"$C\" mcp add evil -- x", "find() { \"$@\"; }; find \"$C\" mcp add evil -- x",
        "xargs -P 4 $c mcp add evil -- x", "xargs -P \"$N\" $c mcp add evil -- x",
        "xargs -I {} $c mcp add {}", "xargs -0P \"$N\" mcp add evil -- x", "xargs -p \"$C\" mcp add evil -- x",
        "watch -n \"$S\" $c mcp add evil -- x", "env \"$KV\" npm run config",
    ])
    func runnerProgramPositionAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    @Test("a dynamic operand a runner never runs allows", arguments: [
        "find $ROOT -type f -name '*.json'", "find . -maxdepth \"$DEPTH\" -name config",
        "find . -maxdepth \"$DEPTH\" -name mcp -delete", "find . -newer \"$REF\" -name plugin -print",
        "find . -maxdepth \"$DEPTH\" -name config -exec cat {} \\;", "xargs -P \"$N\" grep -l config",
        "xargs -n \"$BATCH\" grep -l mcp", "xargs -I {} -P \"$N\" grep -l config {}",
        "watch -n \"$SECS\" cat config", "timeout \"$SECS\" npm run config",
    ])
    func runnerOwnOperandAllows(_ command: String) {
        #expect(judgeSpelling(command) == false, "\(command)")
    }

    /// A dynamic start path still asks: `carriesHostMCPText` re-reads
    /// `find`'s operands joined as a command line (`$DIR -name config`),
    /// whose dynamic head is given a group word. That read is 2dda1e48's;
    /// only the dynamic-word pass over `find`'s own words is narrowed.
    @Test("a dynamic find start path asks through its joined operands")
    func dynamicFindStartPathAsksThroughJoinedOperands() throws {
        for command in ["find \"$DIR\" -name config", "find \"$DIR\" -name mcp -delete"] {
            let find = try #require(launchedCommandHeads(command).first { commandName($0.head) == "find" })
            var plain = HostTextReads()
            plain.commandsArePlain = true
            #expect(isHostMCPMutation(find, reads: &plain) == false, "\(command)")
            var joined = HostTextReads()
            let tail = find.argv.dropFirst().joined(separator: " ")
            #expect(joined.runsHostMCPMutation(tail, nested: false, resplit: true), "\(tail)")
            #expect(judgeSpelling(command), "\(command)")
        }
    }

    /// A segment the splitter cannot scan (a head still `{`/`(` that does not
    /// peel) asks when its line may name a host CLI, bare or carried; one a
    /// command reads as data, and groups that peel, are read as before.
    @Test("an unscannable segment that may name a host asks", arguments: [
        "{claude,mcp} add evil -- x", "{chronic,zzqx} mcp install srv", "x; {claude,zzqx} mcp add evil -- x",
        "watch '{claude,zzqx} mcp add evil -- x'", "echo '(claude) mcp add evil -- x' | sh",
    ])
    func unscannableSegmentAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    @Test("a peeled group or a pattern read as data allows", arguments: [
        "grep -E '(mcp|claude) add' src", "(cd mcp && npm test)", "{ cd mcp; npm test; } 2>&1 | tee log",
        "rg -n '(config|plugin) list' docs",
    ])
    func scannableGroupsAllow(_ command: String) {
        #expect(judgeSpelling(command) == false, "\(command)")
    }

    /// Bash splits a brace word at its commas even where an alternative holds
    /// a blank (`{mcp,"x y"}` is `mcp` and `x y`); a blank outside every
    /// brace stays in every word.
    @Test("a blank inside a brace alternative still splits", arguments: [
        "claude {mcp,add,srv,\"x y\"}", "claude {mcp,add,srv,'x y'}", "chronic {'a b',mcp} install srv",
        "stdbuf -o0 {claude,'x y'} mcp add evil -- x",
    ])
    func blankInBraceAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    @Test("a blank outside every brace keeps the word whole", arguments: [
        "claude -p 'rename {a,b}.ts to ../c'", "codex exec \"use {a, b} = obj in ../src\"",
        "claude -p \"fix {x} in f({a, b}) and g({c, d})\"",
    ])
    func blankOutsideBracesAllows(_ command: String) {
        #expect(judgeSpelling(command) == false, "\(command)")
    }

    /// Words are case-folded before matching, so a class is judged as any
    /// class its folded text may have been: bash matches `cl[M-c]ude` and
    /// `cl[!A-Z]ude` against `claude`.
    @Test("a folded class matches what the unfolded class may")
    func foldedClassGlob() {
        var budget = SpellingBudget()
        for pattern in ["cl[m-c]ude", "cl[b-z]ude", "cl[z-a]ude", "cl[!a-z]ude", "cl[a-c]ude"] {
            #expect(globCanMatch(pattern, "claude", budget: &budget), "\(pattern)")
        }
        #expect(globCanMatch("cl[0-9]ude", "claude", budget: &budget) == false)
        #expect(globCanMatch("cl[x]ude", "claude", budget: &budget) == false)
        #expect(globCanMatch("cl[!.]ude", "cl.ude", budget: &budget) == false)
        #expect(globCanMatch("cl[!0-9]ude", "cl5ude", budget: &budget) == false)
        for command in ["stdbuf -o0 cl[M-c]ude mcp add evil -- x", "stdbuf -o0 cl[!A-Z]ude mcp add evil -- x"] {
            #expect(judgeSpelling(command), "\(command)")
        }
    }

    /// A word past `SpellingBudget.maxWordLength` with no brace whose
    /// shortest match, and its basename's, is longer than every table word
    /// cannot be one; any other long spelled word may be any words.
    @Test("a long glob word is judged by its shortest match")
    func longGlobWords() {
        #expect(shortestGlobMatch("a*b?[cd]") == 4)
        #expect(shortestGlobMatch("[]a]x") == 2)
        #expect(shortestGlobMatch("[ab") == 3)
        #expect(shortestGlobMatch("***") == 0)
        #expect(longestSpelledLiteral >= "@anthropic-ai/claude-code".count)
        let url = "https://bucket.s3.amazonaws.com/f.zip?X-Amz-Algorithm=AWS4-HMAC-SHA256"
            + "&X-Amz-Credential=AKIAEXAMPLE%2F20240101%2Fus-east-1%2Fs3%2Faws4_request"
            + "&X-Amz-Date=20240101T000000Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host"
            + "&X-Amz-Signature=" + String(repeating: "0123456789abcdef", count: 4)
        #expect(url.count > SpellingBudget.maxWordLength)
        #expect(judgeSpelling("curl -o f.zip \"\(url)\"") == false)
        let stars = String(repeating: "*", count: 300)
        let deep = "/" + String(repeating: "d/", count: 150) + "clau?e"
        for command in ["stdbuf -o0 \(stars) mcp add evil -- x", "stdbuf -o0 \(deep) mcp add evil -- x"] {
            #expect(judgeSpelling(command), "\(command.prefix(40))")
        }
    }

    /// The false-positive table from review 12, measured on the guard alone
    /// (gateway in use). `true` asks. An ask row that starts to allow is a
    /// narrowing to re-check against the deny rows, not a failure to restore.
    @Test("everyday commands judge as measured", arguments: [
        ("grep -rn claude *", false), ("rg codex * | head", false), ("ls mcp *", false),
        ("git add mcp *", false), ("cp -r packages/mcp \"$DEST\"", false), ("rm -rf build/mcp $TMP", false),
        ("npm install $PKG", false), ("make $TARGET install", false), ("touch {a..z}{0..9}", false),
        ("mkdir -p {a..h}/{1..9}", false), ("ls ~/Library/Application\\ Support/*", true),
        ("find . -name '*.swift' -exec wc -l {} +", false), ("git commit -m \"fix config $IFS handling\"", false),
        ("claude -p \"explain f() { ... }\"", false), ("for f in *; do echo $f; done", false),
        ("grep -rn \"\\\"version\\\"\" * | head", true), ("cd \"$DIR\" && npm test", false),
        ("npx $PKG --version", false), ("rm -rf \"$TMP\"", false), ("cp -r \"$SRC\" mcp", false),
        // A dynamic word after a program that may run it, with a group word
        // later: it may be a host CLI (`$VAR` is now read as dynamic).
        ("node \"$ENTRY\" mcp list", true),
        // `find`, `xargs` and `watch` never run their own operands; a dynamic
        // start path still asks through the joined operands, as at 2dda1e48.
        ("find \"$DIR\" -name config", true), ("find . -maxdepth \"$DEPTH\" -name config", false),
        ("xargs -P \"$N\" grep -l config", false), ("watch -n \"$SECS\" cat config", false),
        ("timeout \"$SECS\" npm run config", false),
        // A brace word at a may-run operand: expanded within the cap, and
        // past `SpellingBudget.maxWordLength` it may be any words.
        ("curl -d '{\"a\":1,\"b\":2}' https://api.example.com/x", false),
        (MCPHostSpellingTests.longJSONCurl, true),
    ] as [(String, Bool)])
    func everydayVerdicts(_ command: String, _ asks: Bool) {
        #expect(judgeSpelling(command) == asks, "\(command)")
    }

    @Test("brace expansion yields the shell's words")
    func braceExpansionWords() {
        func expand(_ word: String) -> [String]? {
            var budget = SpellingBudget()
            return boundedBraceExpansions(word, budget: &budget)
        }
        #expect(expand("m{c,}p") == ["mcp", "mp"])
        #expect(expand("{,}") == [])
        #expect(expand("{mcp,}") == ["mcp"])
        #expect(expand("mc{o..p}") == ["mco", "mcp"])
        #expect(expand("x{1..3}") == ["x1", "x2", "x3"])
        #expect(expand("x{5..1..2}") == ["x5", "x3", "x1"])
        #expect(expand("{a,{b,c}}") == ["a", "b", "c"])
        #expect(expand("{{a,b}") == ["{a", "{b"])
        #expect(expand("f() { ... }") == ["f() { ... }"])
        #expect(expand("m{b..c..0}p") == ["mbp", "mcp"])
        #expect(expand("a{1..100}") == ["a1"])
        // A `..` group bash cannot enumerate stays text.
        #expect(expand("{a..zz}") == ["{a..zz}"])
        #expect(expand("{...}") == ["{...}"])
        #expect(expand("*{1..100}") == nil)
        #expect(expand("{" + Array(repeating: "a", count: 65).joined(separator: ",") + "}") == nil)
        #expect(expand("{9223372036854775800..9223372036854775807..5}") == ["9223372036854775800", "9223372036854775805"])
        #expect(expand("{-9223372036854775807..9223372036854775807}") == ["-9223372036854775807"])
    }

    /// An over-long integer range stands for one word (`braceRange`): sound
    /// only while no word the guard matches holds a digit.
    @Test("no word the guard matches holds a digit")
    func tableWordsHoldNoDigit() {
        for word in hostMCPTableWords() + ["install"] {
            #expect(word.contains(where: \.isNumber) == false, "\(word)")
        }
    }

    @Test("a POSIX class matches one character of any kind")
    func posixClassGlob() {
        var budget = SpellingBudget()
        #expect(globCanMatch("clau[[:alpha:]]e", "claude", budget: &budget))
        #expect(globCanMatch("m[[=c=]]p", "mcp", budget: &budget))
        #expect(globCanMatch("[:upper:]", "claude", budget: &budget) == false)
        #expect(globCanMatch("clau[[:alpha:]]", "claude", budget: &budget) == false)
    }

    /// Many dynamic words after a runner, none followed by a group word: one
    /// pass over the words, no work per pair. Each word is visited a fixed
    /// number of times (spelling, `LaterWords`, the dynamic-word pass, the
    /// judged pass). The same words before a group word ask.
    @Test("dynamic words are judged in linear word visits")
    func dynamicWordsAreLinear() {
        for dynamic in ["$a", "${a}", "$(a)"] {
            #expect(wordIsDynamic(dynamic), "\(dynamic)")
            let args = ["-o0"] + Array(repeating: dynamic, count: 16_000) + ["x"]
            let command = LaunchedCommand.make(head: "stdbuf", program: "stdbuf", args: args, headIsDynamic: false)
            var reads = HostTextReads()
            #expect(isHostMCPMutation(command, reads: &reads) == false)
            #expect(reads.wordVisits <= 4 * (args.count + 1) + 2)
            #expect(reads.wordVisits >= 4 * (args.count + 1))
            #expect(reads.spelling.steps == 0)
            #expect(judgeSpelling("stdbuf " + args.joined(separator: " ")) == false)
            let grouped = LaunchedCommand.make(
                head: "stdbuf", program: "stdbuf", args: args + ["mcp"], headIsDynamic: false)
            var groupedReads = HostTextReads()
            #expect(isHostMCPMutation(grouped, reads: &groupedReads))
        }
    }

    /// A ~64 KiB line of dynamic words, star-heavy globs, a long run of `{`
    /// and a long `*` word: the dynamic words ask before any group word is
    /// spelled, the spelling work stops at the budget and the line asks (fail
    /// closed); word visits stay linear.
    @Test("an adversarial line is judged within the spelling budget")
    func adversarialLineIsBounded() {
        let stars = (0..<200).map { index in
            String(repeating: "*a", count: 120) + "*" + String(Character(UnicodeScalar(UInt8(98 + index % 20))))
        }
        let args = ["-o0"] + Array(repeating: "${a}", count: 2_000) + stars
            + [String(repeating: "{", count: 4_000) + ",", String(repeating: "*a", count: 2_000)]
        let line = "stdbuf " + args.joined(separator: " ")
        #expect(line.utf8.count > 60_000)
        let command = LaunchedCommand.make(head: "stdbuf", program: "stdbuf", args: args, headIsDynamic: false)
        var reads = HostTextReads()
        #expect(isHostMCPMutation(command, reads: &reads))
        #expect(reads.spelling.steps <= SpellingBudget.maxSteps)
        #expect(reads.wordVisits <= 4 * (args.count + 1) + 2)
        // The stars alone, with nothing rv cannot expand after them.
        let starArgs = ["-o0"] + stars + ["x"]
        let starCommand = LaunchedCommand.make(head: "stdbuf", program: "stdbuf", args: starArgs, headIsDynamic: false)
        var starReads = HostTextReads()
        _ = isHostMCPMutation(starCommand, reads: &starReads)
        #expect(starReads.spelling.steps <= SpellingBudget.maxSteps)
        #expect(starReads.wordVisits <= 4 * (starArgs.count + 1) + 2)
        var lineReads = HostTextReads()
        #expect(judgeSpelling(line, &lineReads))
        #expect(lineReads.spelling.steps <= SpellingBudget.maxSteps)
        #expect(lineReads.readsDone <= HostTextReads.maxReads)
    }
}

/// The MCP guard's verdict on `command` in isolation: true asks.
private func judgeSpelling(_ command: String) -> Bool {
    var reads = HostTextReads()
    return judgeSpelling(command, &reads)
}

/// `judgeSpelling` spending `reads`.
private func judgeSpelling(_ command: String, _ reads: inout HostTextReads) -> Bool {
    let context = FilesystemAnalysisContext(homeDirectory: nil, mcpHostConfigGuard: MCPHostConfigGuard())
    return mcpHostConfigUnmodeledWrite(command, guard: MCPHostConfigGuard(), context: context, reads: &reads)
}
