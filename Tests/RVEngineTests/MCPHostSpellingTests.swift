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
    /// ask as their literal forms (`ls mcp install`) always have.
    @Test("a spelled operand of a program that may run still asks", arguments: [
        "ls mcp *", "git add mcp *", "ls mcp $DIR",
    ])
    func runnableSpelledOperandAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
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
    /// pass over the words, no work per pair.
    @Test("dynamic words are judged in linear word visits")
    func dynamicWordsAreLinear() {
        let args = ["-o0"] + Array(repeating: "$a", count: 16_000) + ["x"]
        let command = LaunchedCommand.make(head: "stdbuf", program: "stdbuf", args: args, headIsDynamic: false)
        var reads = HostTextReads()
        #expect(isHostMCPMutation(command, reads: &reads) == false)
        #expect(reads.wordVisits <= 3 * (args.count + 1) + 2)
        #expect(reads.spelling.steps == 0)
        #expect(judgeSpelling("stdbuf " + args.joined(separator: " ")) == false)
    }

    /// A ~64 KiB line of dynamic words, star-heavy globs, a long run of `{`
    /// and a long `*` word: the spelling work stops at the budget and the
    /// line asks (fail closed); word visits stay linear.
    @Test("an adversarial line is judged within the spelling budget")
    func adversarialLineIsBounded() {
        let stars = (0..<200).map { index in
            String(repeating: "*a", count: 120) + "*" + String(Character(UnicodeScalar(UInt8(98 + index % 20))))
        }
        let args = ["-o0"] + Array(repeating: "$a", count: 2_000) + stars
            + [String(repeating: "{", count: 4_000) + ",", String(repeating: "*a", count: 2_000)]
        let line = "stdbuf " + args.joined(separator: " ")
        #expect(line.utf8.count > 60_000)
        let command = LaunchedCommand.make(head: "stdbuf", program: "stdbuf", args: args, headIsDynamic: false)
        var reads = HostTextReads()
        #expect(isHostMCPMutation(command, reads: &reads))
        #expect(reads.spelling.steps <= SpellingBudget.maxSteps)
        #expect(reads.wordVisits <= 3 * (args.count + 1) + 2)
        // The stars alone, with nothing rv cannot expand after them.
        let starArgs = ["-o0"] + stars + ["x"]
        let starCommand = LaunchedCommand.make(head: "stdbuf", program: "stdbuf", args: starArgs, headIsDynamic: false)
        var starReads = HostTextReads()
        _ = isHostMCPMutation(starCommand, reads: &starReads)
        #expect(starReads.spelling.steps <= SpellingBudget.maxSteps)
        #expect(starReads.wordVisits <= 3 * (starArgs.count + 1) + 2)
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
