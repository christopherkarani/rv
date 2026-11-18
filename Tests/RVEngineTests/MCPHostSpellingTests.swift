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

    /// A brace or class span holding a blank or a separator (`{clau?e,x y}`,
    /// `cl[;a]ude`): quoted, the shell keeps it one word, and the guard
    /// expands that word whole. The prefilters split text at blanks and
    /// separators before spelling it, and so passed over such words.
    static let brokenSpanSpellings: [String] = [
        #"$x "env '{clau?e,x y}' '{m?p,x y}' add s -- x""#,
        #"$x "sudo 'cl[;a]ude' 'm[;c]p' add s -- x""#,
        #"watch "env '{clau?e,x y}' '{m?p,x y}' add s -- x""#,
        #"watch "'cl[;a]ude' 'm[;c]p' add s -- x""#,
        #"echo "env '{clau?e,x|y}' '{m?p,x&y}' add s -- x" | sh"#,
        #"stdbuf -o0 '{clau?e,x y}' '{m?p,x y}' add s -- x"#,
        #"chronic 'm[;c]p' 'i[(n]stall' srv"#,
        #"watch "'cl[[:alpha:];]ude' 'm[[:alpha:];]p' add s -- x""#,
        #"watch "echo [; env '{clau?e,x y}' '{m?p,x y}' add s -- x ]""#,
        #"watch "echo {; env '{clau?e,x y}' '{m?p,x y}' add s -- x }""#,
        #"$x "echo [; env 'cl[!;]ude' 'm[[:alpha:]|]p' add s -- x ]""#,
        "watch 'npx install-m[x]cp srv'", "$x \"npx ge[x]mini-cli m?p add s\"", "watch 'xargs npx ge[x]mini-cli'",
        #"watch "'{c?aude,x y}{,a b}' 'm[;c]p' add s -- x""#,
        #"watch "echo [; '{c?aude,x y}{,a b}' 'm[;c]p' add s -- x ]""#,
        // A class crossing a brace whose `}` lies past the quoted word: the
        // word is the class and the inner group, which no chain of runs is.
        #"watch "'cl[;x{;{y;a]ude,;}' $g add s -- x }""#,
    ]

    @Test("a spelling with a blank or separator inside a span still asks", arguments: brokenSpanSpellings)
    func brokenSpanSpellingAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    /// The prefilter closes classes on the text as written; the guard
    /// expands braces first, so an alternative that supplies a `]` closes a
    /// class (`cl[];a]ude`) the written text closes earlier. Asking wherever
    /// a comma group holds a bracket made everyday `jq` and `awk` programs
    /// ask, so this stays a known limit.
    @Test("a class a brace alternative closes is a known limit")
    func braceClosedClassIsKnownLimit() {
        withKnownIssue("a class closed by a brace alternative") {
            #expect(judgeSpelling(#"watch "'cl[{],x};a]ude' 'm[{],x};c]p' add s -- x""#))
        }
    }

    /// Each payload word, alone and all at once, inside a span holding a
    /// blank or a separator.
    static let brokenSpanCases: [String] = {
        let spans: [@Sendable (String) -> String?] = [
            { w in w.count >= 3 ? "'{\(w),x y}'" : nil },
            { w in w.count >= 3 ? "'{\(w),x;y}'" : nil },
            { w in w.count >= 3 ? "'{\(w),x|y}'" : nil },
            { w in w.count >= 3 ? "'\(w.first!)[;\(Array(w)[1])]\(w.dropFirst(2))'" : nil },
            { w in w.count >= 3 ? "'\(w.first!)[ <\(Array(w)[1])]\(w.dropFirst(2))'" : nil },
            { w in w.count >= 3 ? "'{\(w.first!)?\(w.dropFirst(2)),x y}'" : nil },
            { w in w.count >= 3 ? "'{\(w.first!)?\(w.dropFirst(2)),x;y}'" : nil },
            { w in w.count >= 3 ? "'\(w.first!)[[:alpha:];]\(w.dropFirst(2))'" : nil },
            { w in w.count >= 3 ? "'\(w.first!)[!;]\(w.dropFirst(2))'" : nil },
        ]
        var lines: [String] = []
        for payload in Self.payloads {
            for span in spans {
                for position in payload.indices {
                    guard let spelled = span(payload[position]) else { continue }
                    var words = payload
                    words[position] = spelled
                    lines.append(words.joined(separator: " "))
                }
                lines.append(payload.map { span($0) ?? $0 }.joined(separator: " "))
            }
        }
        return lines.flatMap { line in
            [line, "stdbuf -o0 \(line)", "watch \(shQuoted(line))", "$x \(shQuoted("env " + line))"]
        }
    }()

    /// The prefilters never say no where the full judgement could say yes:
    /// a command `isHostMCPMutation` matches, as a fixture line or text it
    /// carries launches it, passes `commandMayNameHostMCP` (the speculative
    /// command prefilter), and the text holding it passes `mayNameHostMCP`
    /// (the prefilter every read begins with). Enough matched commands hold
    /// no stem in any word, even past `[…]` extras, so the spelling path is
    /// what passes them (113 when this floor was set).
    @Test("a prefilter passes whatever the full judgement matches")
    func prefilterCoversFullJudgement() {
        let lines = Self.spellingCases.map(\.command) + Self.brokenSpanSpellings + Self.brokenSpanCases
        let checks = lines.map(prefilterCheck)
        let violations = checks.flatMap(\.violations)
        let spelled = checks.reduce(0) { $0 + $1.spelled }
        #expect(violations.isEmpty, "\(violations.count): \(violations.prefix(12))")
        #expect(spelled >= 110, "\(spelled) matched commands hold no stem")
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
        "git add mcp install", "ls 'npx install-m[x]cp srv'", "grep 'npx install-m[x]cp srv' docs/",
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

    /// A redefinition rv already parsed but the line's text does not spell
    /// as `PATH=`: zsh's tied `path` array, a quoted name given to `env`,
    /// a shell startup file (`BASH_ENV`, `ENV`, `ZDOTDIR`), and `PATH` set
    /// by `read`, `printf -v` or a `for` loop.
    @Test("the operand list backs off where a parsed assignment may move a command", arguments: [
        "path=(./bin $path); ls mcp $X", "path+=(./bin); ls mcp $X", "path[1]=./bin; ls mcp $X",
        "env 'PA'TH=./bin:$PATH ls mcp $X", "BASH_ENV=./x.sh bash -c 'ls mcp $X'",
        "ENV=./x.sh sh -c 'ls mcp $X'", "ZDOTDIR=./z zsh -c 'ls mcp $X'", "export BASH_ENV=./x.sh; bash -c 'ls mcp $X'",
        "export 'PA'TH=./bin; ls mcp $X",
        "read PATH; ls mcp $X", "printf -v PATH %s ./bin; ls mcp $X", "for PATH in ./bin; do ls mcp $X; done",
    ])
    func parsedRedefinitionAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    /// Any construct that names a lookup variable (`PATH`, zsh `path`,
    /// `fpath`, `module_path`, `BASH_ENV`, `ENV`, `ZDOTDIR`) other than a
    /// plain `$NAME` read, `env` told to search elsewhere or split a string,
    /// an autoload, or text a shell reads beside output rv cannot read.
    @Test("the operand list backs off wherever a lookup may change", arguments: [
        "env -P ./bin ls mcp $X", "env -P./bin ls mcp $X", "env -P ./bin ls {claude,mcp} add evil -- x",
        "env -iP ./bin ls mcp $X", "env -S 'ls mcp $X'",
        "unset PATH; : \"${PATH:=./bin}\"; ls mcp $X", ": ${PATH=./bin}; ls mcp $X", "unset PATH; ls mcp $X",
        "path=./bin; ls mcp $X", "PATH[1,0]=./bin:; ls mcp $X", "for path (./bin) ls mcp $X",
        "fpath+=./fn; typeset -fu ls; ls mcp $X", "typeset -fu ls; ls mcp $X", "module_path+=./m; ls mcp $X",
        "declare -n p=PATH; p=./bin:$PATH; ls mcp $X", "mapfile -t PATH <<< ./bin; ls mcp $X",
        "readarray -t PATH < ./p; ls mcp $X", "read -a PATH <<< ./bin; ls mcp $X",
        "{ cat ./defs.sh; echo 'ls mcp $X'; } | sh", "PA\\\nTH=./bin:$PATH; ls mcp $X",
        "printf -vPATH %s ./bin; ls mcp $X", "let 'PATH = 1'; ls mcp $X", "(( PATH = 1 )); ls mcp $X",
    ])
    func lookupChangeAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    /// A name written as a `$'…'` or `$"…"` word is the name, not a `$NAME`
    /// read; an operand of an assigning builtin whose name holds `$` or a
    /// backtick may build one from escapes or expansions; zsh's
    /// `${NAME::=…}` and an element's `${name[1]:=…}` assign; GNU `env`
    /// takes `--split` for `--split-string`.
    @Test("the operand list backs off where a quoted or expanded name may assign", arguments: [
        #"export $'PATH'=./bin; ls mcp $X"#, #"declare $"PATH"=./bin; ls mcp $X"#,
        #"typeset $'PATH'=./bin; ls mcp $X"#, #"local $'PATH'=./bin; ls mcp $X"#,
        #"readonly $"PATH"=./bin; ls mcp $X"#, #"printf -v $'PATH' %s ./bin; ls mcp $X"#,
        #"unset $'PATH'; ls mcp $X"#, #"read $'PATH'; ls mcp $X"#,
        #"export $'PA\x54H'=./bin; ls mcp $X"#, #"unset $'PA\x54H'; ls mcp $X"#,
        #"printf -v $'PA\x54H' %s ./bin; ls mcp $X"#,
        ": ${PATH::=./bin}; ls mcp $X", ": ${path[1]:=./bin}; ls mcp $X",
        "env --split 'ls mcp $X'", "env --s 'ls mcp $X'", "env --split-str='ls mcp $X'",
        #"export P$'\x41'TH=./bin; ls mcp $X"#, #"printf -v$'PA\x54H' %s ./bin; ls mcp $X"#,
        "N=PA; export ${N}TH=./bin; ls mcp $X", "export P`echo A`TH=./bin; ls mcp $X",
        "declare -x \"P${A}TH\"=./bin; ls mcp $X", "readonly P$(echo A)TH; ls mcp $X",
    ])
    func spelledLookupChangeAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    /// A nameref's target is the value after `=`, which is not read as a
    /// name: built from an expansion, it is a known limit.
    @Test("a nameref to an expanded lookup name is a known limit")
    func expandedNamerefIsKnownLimit() {
        withKnownIssue("a nameref whose target is an expansion") {
            #expect(judgeSpelling("N=PA; declare -n R=${N}TH; R=./bin; ls mcp $X"))
        }
    }

    @Test("the operand list holds where an expansion only reads a lookup variable", arguments: [
        "ls mcp $X ${PATH:-/usr/bin}", "ls mcp $X ${PATH: -3}", "ls mcp $X ${PATH:0:3}", "ls mcp $X ${#PATH}",
        "ls mcp $X ${PATH#*:}", "ls mcp $X ${PATH/x/y}", "printf '%s\\n' x; ls mcp $X",
        "export FOO=$BAR; ls mcp $X", "export CFLAGS=\"$CFLAGS -O2\" LDFLAGS=${LDFLAGS}; ls mcp $X",
        "local dir=$(pwd); ls mcp $X",
        // `printf` assigns only through `-v`: a `$` format or value word,
        // beside a `$'…'` word, names nothing.
        #"printf $'%s\n' "$NAME"; ls mcp $X"#, #"printf -v out $'%s' "$NAME"; ls mcp $X"#,
        #"printf '%s' $'\t' "$V"; ls mcp $X"#,
    ])
    func expandedLookupReadAllows(_ command: String) {
        #expect(judgeSpelling(command) == false, "\(command)")
    }

    /// Reading a lookup variable, or a word that only contains its name,
    /// changes nothing: the operand list still holds.
    @Test("the operand list holds where a lookup variable is only read", arguments: [
        "echo \"$PATH\"; ls mcp $X", "ls mcp $X ${PATH%%:*}", "cp -r mcp $OUTPUT_PATH",
        "ls mcp $X ~/path/to", "env ls mcp $X", "env -i ls mcp $X",
    ])
    func lookupReadAllows(_ command: String) {
        #expect(judgeSpelling(command) == false, "\(command)")
    }

    /// Text the line carries and rv reads again as a command line is
    /// checked for redefinitions on its own: its heads are not the line's.
    @Test("the operand list backs off where carried text may define commands", arguments: [
        "watch 'source ./lib.sh; find \"$C\" mcp add evil -- x'", "echo 'alias ls=eval; ls mcp $X' | sh",
        "watch $'ls\\x28\\x29 { eval \"$@\"; }; ls mcp $X'", "watch 'alias ls=eval; ls mcp $X'",
        "echo 'source ./lib.sh; ls mcp $X' | sh",
    ])
    func carriedRedefinitionAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    @Test("the operand list holds on a line that defines nothing", arguments: [
        "ls mcp $X", "ls -la mcp $X", "cd \"$DIR\" && ls mcp $X",
    ])
    func plainOperandListAllows(_ command: String) {
        #expect(judgeSpelling(command) == false, "\(command)")
    }

    /// A dynamic word after `find`, `xargs` or `watch`, with a group word
    /// later, asks wherever it stands. rv's words lost their quoting, so
    /// `"$N"` may be an unquoted `$N` that splits into an `-exec` clause or
    /// a program (`N='4 claude'`), and a quoted `'\;'` reads as the `;`
    /// that ends a clause though `find` keeps going.
    @Test("a dynamic operand of find, xargs or watch may be a program and asks", arguments: [
        "c=claude; o=-exec; find . $o $c mcp add evil -- x \\;",
        "D='-exec claude'; find . $D mcp add evil -exec cat {} \\;",
        "find . -maxdepth \"$DEPTH\" -name config", "find . -maxdepth \"$DEPTH\" -name mcp -delete",
        "find . -newer \"$REF\" -name plugin -print", "find . -maxdepth \"$DEPTH\" -name config -exec cat {} \\;",
        "c=claude; find . -exec sh -c 'shift; exec \"$@\"' sh '\\;' $c mcp add evil -- x \\;",
        "c=claude; find . -exec sh -c 'shift; exec \"$@\"' sh \"\\;\" $c mcp add evil -- x \\;",
        "c=claude; find . -ok sh -c 'exec \"$@\"' sh {} + $c mcp add evil -- x \\;",
        "N='4 claude'; echo x | xargs -P $N mcp add evil -- x", "xargs --max-procs $N mcp add evil -- x",
        "xargs -P \"$N\" grep -l config", "xargs -n \"$BATCH\" grep -l extensions",
        "xargs -I {} -P \"$N\" grep -l config {}",
        "S='1 claude'; watch -n $S mcp add evil -- x", "watch -n \"$SECS\" cat config",
    ])
    func runnerDynamicOperandAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

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

    /// A program rv does not list as a runner, given options before the
    /// host, may still run it: the host's words after those options are
    /// read as their own command line, so a dynamic group word or a
    /// dynamic head there asks as it does with no options.
    @Test("a host after an unlisted wrapper's options asks with a dynamic word", arguments: [
        "strace -f claude \"$(printf mcp)\" add evil -- npx -y evil-mcp",
        "C=claude; strace -f $C mcp add evil -- npx evil",
        "xvfb-run -a claude $(printf mcp) add evil -- x",
        "firejail --quiet claude $SUB add evil -- x",
        "strace -o out.txt claude $SUB add evil -- x",
        "strace -o out.txt $C mcp add evil -- x",
    ])
    func unlistedWrapperWithOptionsAsks(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    /// Host names before the real one do not use up the re-reads: every
    /// host or dynamic word after the options is read from.
    @Test("a host after decoy hosts in a wrapper's options asks", arguments: [
        "strace -o cursor -o cursor -o cursor -o cursor -f claude $SUB add evil -- x",
    ])
    func decoyHostsBeforeWrappedHostAsk(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    /// A dynamic word that is the value of an option naming a path or a
    /// context (`git -C`, `tar -C`, `docker -f`, `kubectl --context`) is no
    /// program those run, so a group word after it is no host's; nor are
    /// many option values the re-reads go through.
    @Test("a path option's dynamic value, or many option values, with a group word allow", arguments: [
        "docker compose -f \"$COMPOSE_FILE\" config",
        "git -C \"$REPO\" config --get remote.origin.url",
        "kubectl --context \"$C\" config view",
        "tar -C \"$D\" -xf x.tgz config",
        "curl -H \"$A\" -H \"$B\" -H \"$C\" -H \"$D\" -H \"$E\" https://example.com/config",
        "docker run -e A=\"$A\" -e B=\"$B\" -e C=\"$C\" -e D=\"$D\" -e E=\"$E\" image config",
        "git -c a=\"$A\" -c b=\"$B\" -c c=\"$C\" -c d=\"$D\" -c e=\"$E\" config --list",
    ])
    func pathOptionValueWithGroupAllows(_ command: String) {
        #expect(judgeSpelling(command) == false, "\(command)")
    }

    /// The nearest ways those programs run something still ask: a word
    /// after the path value, a program given to another option, a git
    /// alias, a container or pod command, and a line that redefines the
    /// program.
    @Test("a command those programs run still asks", arguments: [
        "git -C \"$REPO\" $C mcp add evil -- x",
        "git -c alias.x='!claude mcp add evil' x",
        "git -C \"$REPO\" -c alias.x='!claude mcp add evil' x",
        "alias git=strace; git -C \"$C\" mcp add evil -- x",
        "tar -C \"$D\" --to-command='claude mcp add evil' -xf x.tgz",
        "tar -C \"$D\" -I \"$P\" -xf x.tgz mcp add evil",
        "docker compose -f \"$F\" run svc claude mcp add evil -- x",
        "docker compose -f \"$F\" exec -T svc $X mcp add evil -- x",
        "kubectl --context \"$C\" exec pod -- claude mcp add evil -- x",
        "kubectl --context \"$C\" exec pod -- $X mcp add evil -- x",
    ])
    func pathOptionProgramsStillAsk(_ command: String) {
        #expect(judgeSpelling(command), "\(command)")
    }

    /// Bounds, not pins: these allow because no group word follows the
    /// dynamic word (`*.json` cannot be one) or the parser drops it (a
    /// `timeout` duration), as they did before any runner operand was read.
    @Test("a dynamic word with no group word after it allows", arguments: [
        "find $ROOT -type f -name '*.json'", "timeout \"$SECS\" npm run config",
    ])
    func dynamicWordWithoutGroupAllows(_ command: String) {
        #expect(judgeSpelling(command) == false, "\(command)")
    }

    /// A dynamic start path asks from `find`'s own words, and again through
    /// `carriesHostMCPText`'s re-read of its operands joined as a command
    /// line (`$DIR -name config`), whose dynamic head is given a group word.
    @Test("a dynamic find start path asks from its words and its joined operands")
    func dynamicFindStartPathAsksThroughJoinedOperands() throws {
        for command in ["find \"$DIR\" -name config", "find \"$DIR\" -name mcp -delete"] {
            let find = try #require(launchedCommandHeads(command).first { commandName($0.head) == "find" })
            var plain = HostTextReads()
            plain.commandsArePlain = true
            #expect(isHostMCPMutation(find, reads: &plain), "\(command)")
            var joined = HostTextReads()
            let tail = find.argv.dropFirst().joined(separator: " ")
            let joinedAsks = joined.runsHostMCPMutation(tail, nested: false, resplit: true)
            #expect(joinedAsks, "\(tail)")
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
        // A dynamic operand of `find`, `xargs` or `watch` with a group word
        // later asks: unquoted, it may split into a program.
        ("find \"$DIR\" -name config", true), ("find . -maxdepth \"$DEPTH\" -name config", true),
        ("xargs -P \"$N\" grep -l config", true), ("watch -n \"$SECS\" cat config", true),
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

    /// A run of `[` that never closes, and a run of `[[:`, cost one scan of
    /// the text: a class scan per `[` once took about n² and n³ steps (16 KiB
    /// of `[` some two minutes, 2 KiB of `[[:` about one). The bound is
    /// loose on purpose; `classTableAgreesWithScan` checks the answers.
    @Test("a run of brackets is scanned in linear time", arguments: [
        String(repeating: "[", count: 16_384), String(repeating: "[[:", count: 683),
    ])
    func bracketRunIsLinear(_ run: String) {
        var named = true
        var asks = true
        let elapsed = ContinuousClock().measure {
            named = mayNameHostMCP(run)
            asks = judgeSpelling("watch '\(run)'")
        }
        #expect(named == false)
        #expect(asks == false)
        #expect(elapsed < .seconds(30), "\(elapsed)")
    }

    /// The class table closes each class where the per-`[` scan it replaced
    /// did: `shortestGlobMatch`, which counts a closed class once, agrees
    /// with a copy of that scan on every pattern up to six characters over
    /// `[]:=.!^a` (so on every suffix of each, too). The table is private,
    /// so whether a class holds a POSIX class is left to the spelling rows
    /// (`[[:alpha:]]`).
    @Test("the class table closes classes where the old scan did")
    func classTableAgreesWithScan() {
        let alphabet = Array("[]:=.!^a")
        var patterns: [[Character]] = [[]]
        var frontier: [[Character]] = [[]]
        for _ in 0..<6 {
            frontier = frontier.flatMap { prefix in alphabet.map { prefix + [$0] } }
            patterns += frontier
        }
        var mismatches: [String] = []
        for pattern in patterns {
            let shipped = shortestGlobMatch(String(pattern))
            let reference = referenceShortestGlobMatch(pattern)
            if shipped != reference { mismatches.append("\(String(pattern)): \(shipped) vs \(reference)") }
        }
        #expect(patterns.count == 299_593)
        #expect(mismatches.isEmpty, "\(mismatches.count): \(mismatches.prefix(8))")
    }
}

/// `shortestGlobMatch` as it was, over the per-`[` class scan below.
private func referenceShortestGlobMatch(_ p: [Character]) -> Int {
    var count = 0
    var index = 0
    while index < p.count {
        if p[index] == "*" {
            index += 1
            continue
        }
        if p[index] == "[", let close = referenceClassEnd(p, index) {
            index = close + 1
        } else {
            index += 1
        }
        count += 1
    }
    return count
}

/// The class scan the table replaced: from `open` to the `]` that closes
/// it, skipping each `[:…:]`, `[=…=]` or `[.….]`; nil when none does.
private func referenceClassEnd(_ p: [Character], _ open: Int) -> Int? {
    var k = open + 1
    if k < p.count, p[k] == "!" || p[k] == "^" { k += 1 }
    if k < p.count, p[k] == "]" { k += 1 }
    while k < p.count, p[k] != "]" {
        if p[k] == "[", k + 1 < p.count, ":=.".contains(p[k + 1]) {
            let kind = p[k + 1]
            var j = k + 2
            while j + 1 < p.count, (p[j] == kind && p[j + 1] == "]") == false { j += 1 }
            if j + 1 < p.count {
                k = j + 2
                continue
            }
        }
        k += 1
    }
    return k < p.count ? k : nil
}

/// Where a prefilter says no and the full judgement yes, for `line` and the
/// blank-holding words its commands carry (as written and ANSI-C decoded),
/// read the way `carriesHostMCPText` reads them; and how many matched
/// commands hold no stem in any word.
private func prefilterCheck(_ line: String) -> (violations: [String], spelled: Int) {
    var texts = [line]
    var violations: [String] = []
    var spelled = 0
    var index = 0
    while index < texts.count, index < 64 {
        let text = texts[index]
        index += 1
        let launched = launchedCommandHeads(text)
        var matched = false
        for command in launched {
            var reads = HostTextReads()
            guard isHostMCPMutation(command, reads: &reads) else { continue }
            matched = true
            if ([command.head] + command.guardArgv).allSatisfy({ holdsHostMCPStem($0) == false }) { spelled += 1 }
            var budget = SpellingBudget()
            var named: [String: Bool] = [:]
            if commandMayNameHostMCP(command, budget: &budget, named: &named) == false {
                violations.append("command \(command.guardArgv) of \(line)")
            }
        }
        if matched, mayNameHostMCP(text) == false { violations.append("text \(text) of \(line)") }
        for command in launched {
            for word in command.argv.dropFirst() + command.assignments where word.contains(where: \.isWhitespace) {
                for variant in [word, word.ansiCDecodedIfMarked] where texts.contains(variant) == false {
                    texts.append(variant)
                }
            }
        }
    }
    return (violations, spelled)
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
