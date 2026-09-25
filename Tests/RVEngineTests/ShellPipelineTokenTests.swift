import Testing
@testable import RVEngine

// MARK: - Parity with the legacy byte-loop tokenizer

@Suite struct ShellPipelineTokenParityTests {
    @Test(arguments: parityCorpus)
    func tokenize_matchesLegacyByteLoop(input: String) {
        expectParity(input)
    }

    @Test func tokenize_specExample() {
        let tokens = ShellPipeline.tokenize(#"rm -- "a b" 'c"d' --force"#)
        #expect(tokens.map(\.lexeme) == ["rm", "--", "a b", #"c"d"#, "--force"])
        #expect(tokens.map(\.wasQuoted) == [false, false, true, true, false])
        #expect(tokens.allSatisfy { $0.wasAnsiC == false })

        let argv = Argv(tokens: tokens)
        #expect(argv?.program == "rm")
        #expect(argv?.args == ["--", "a b", #"c"d"#, "--force"])
    }
}

private func expectParity(
    _ input: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let legacy = tokenizeCommand(input)
    let tokens = ShellPipeline.tokenize(input)
    #expect(tokens.map(\.lexeme) == legacy.map(\.decoded), sourceLocation: sourceLocation)
    #expect(tokens.map(\.wasQuoted) == legacy.map(\.wasQuoted), sourceLocation: sourceLocation)
    #expect(tokens.map(\.wasAnsiC) == legacy.map(\.wasAnsiC), sourceLocation: sourceLocation)
}

private let parityCorpus: [String] = [
    "",
    " ",
    "   \t  ",
    "git",
    "  sudo git reset --hard  ",
    #""git" reset --'hard' "$(git reset --hard)" `git status`"#,
    #"git commit -m "" "git push --force""#,
    "rm -r'f' /",
    "rm -'r'f /",
    "rm $'-rf' /",
    #"rm $'\x2d\x72\x66' /"#,
    #"rm $'-\x72\x66' /"#,
    #"$'\x72m -rf /'"#,
    "bash -c $'git reset --hard'",
    "echo $'git reset --hard'",
    "echo a\ngit status",
    "echo a\r\ngit status",
    "echo a\rb\ngit status",
    "echo a\n\n\n\ngit status",
    "\n",
    "\n\n",
    "echo 'a\nb'",
    #"echo "a\nb""#,
    "echo \"\n\"",
    "echo \"abc",
    "echo 'abc",
    "echo $(git status",
    "echo $((1 + (2)))",
    "echo $()",
    "echo $(",
    "echo `abc",
    "echo `a`b`c`",
    "echo $'abc",
    "echo $'",
    "echo $",
    "echo $x",
    "echo $$",
    "echo ${TMPDIR}/build",
    #"a"b"c'd'e"#,
    "$'a'$'b'",
    "'a'$'b'\"c\"",
    "echo héllo 世界",
    "echo\u{00A0}nbsp\u{2003}em",
    "printf\tx\u{0B}y\u{0C}",
    "$'a\\nb\\t\\x41\\101\\e\\E\\r\\v\\f\\b\\a\\?\\\"\\'\\\\'",
    "echo \"$('(')\"",
    "echo '$(x)'",
    "a\"b c\"d e'f g'h",
    "one\"\"two",
    "\"\"",
    "''",
    "\"\" \"\"",
    "a;b|c&d<e>f(g)",
    "echo ok; git reset --hard",
    "cat <<'EOF' | bash\ngit reset --hard\nEOF",
    "python3 -c \"print('git reset --hard')\"",
    #"node --eval=require('child_process').execSync('git reset --hard')"#,
    "find . -name '*rm -rf*'",
    "git log --grep='git reset --hard'",
    ">/etc/passwd",
    "1>/etc/passwd",
    "&>/etc/passwd",
    "\\git reset --hard",
    "/usr/bin/git reset --hard",
    "a\u{0301}b",
]

// MARK: - Vocabulary

@Suite struct ShellPipelineVocabularyTests {
    @Test func token_defaultsAndNewline() {
        #expect(Token(lexeme: "git", wasQuoted: false).wasAnsiC == false)
        #expect(Token(lexeme: "\n", wasQuoted: false).isNewline)
        #expect(Token(lexeme: "\n", wasQuoted: true).isNewline == false)
        #expect(Token(lexeme: "\n", wasQuoted: false, wasAnsiC: true).isNewline == false)
        #expect(Token(lexeme: "a\nb", wasQuoted: true).isNewline == false)
        #expect(Token(lexeme: "git", wasQuoted: false).description == "git")
    }

    @Test func token_marksInlineCode() {
        #expect(Token(lexeme: "$(git status)", wasQuoted: false).containsInlineCode)
        #expect(Token(lexeme: "`git status`", wasQuoted: false).containsInlineCode)
        #expect(Token(lexeme: "git status", wasQuoted: false).containsInlineCode == false)
    }

    @Test func argv_defaultsAndFullCommand() {
        let argv = Argv(program: "rm")
        #expect(argv.args == [])
        #expect(argv.redacted == [])
        #expect(argv.fullCommand == ["rm"])
        #expect(Argv(program: "rm", args: ["-rf", "/"]).fullCommand == ["rm", "-rf", "/"])
    }

    @Test func argv_redactionMarks() {
        var argv = Argv(program: "git", args: ["commit", "-m", "oops"])
        #expect(argv.isRedacted(at: 2) == false)
        argv.markRedacted(at: 2)
        #expect(argv.isRedacted(at: 2))
        argv.markRedacted(at: 9)
        argv.markRedacted(at: -1)
        #expect(argv.redacted == [2])

        let masked = argv.markingRedacted(at: 0)
        #expect(masked.redacted == [0, 2])
        #expect(argv.redacted == [2])

        #expect(Argv(program: "g", args: ["a"], redacted: [0, 7, -1]).redacted == [0])
    }

    @Test func argv_fromTokens() {
        #expect(Argv(tokens: []) == nil)
        #expect(Argv(tokens: [Token(lexeme: "\n", wasQuoted: false)]) == nil)
        let argv = Argv(tokens: [
            Token(lexeme: "git", wasQuoted: false),
            Token(lexeme: "\n", wasQuoted: false),
            Token(lexeme: "status", wasQuoted: true),
            // Quoted newline is data, not a separator: it must survive the
            // structural-newline filter.
            Token(lexeme: "\n", wasQuoted: true),
        ])
        #expect(argv?.program == "git")
        #expect(argv?.args == ["status", "\n"])
        #expect(argv?.redacted == [])
    }
}

// MARK: - Property tests (seeded, deterministic)

private struct XorShift64: Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x == 0 ? 0x9E37_79B9_7F4A_7C15 : x
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }

    mutating func nextElement<T>(_ array: [T]) -> T {
        array[nextInt(upperBound: array.count)]
    }
}

@Suite struct ShellPipelineTokenPropertyTests {
    /// Round-trip: re-emitting lexemes (quoting words with whitespace,
    /// newlines as newlines) and retokenizing yields identical tokens.
    @Test func tokenize_roundTrip() {
        var rng = XorShift64(state: 0x29F1_8C88_543A_9B11)
        for _ in 0..<500 {
            let lexemes = randomLexemes(rng: &rng)
            let emitted = emit(lexemes: lexemes, rng: &rng, trailingSeparator: true)
            let tokens = ShellPipeline.tokenize(emitted.text)
            #expect(tokens.map(\.lexeme) == emitted.expected)
            let requoted = emit(
                lexemes: tokens.map(\.lexeme),
                rng: &rng,
                trailingSeparator: false,
                newlineSeparators: false
            )
            #expect(ShellPipeline.tokenize(requoted.text) == tokens)
        }
    }

    /// Differential fuzz: randomized adversarial inputs tokenize identically
    /// to the legacy byte loop on lexeme and both provenance flags.
    @Test func tokenize_differentialParity() {
        var rng = XorShift64(state: 0xC0FF_EE11_1979_0109)
        let alphabet = Array("aZ0-_/. ").map(String.init)
            + ["\"", "'", "$", "(", ")", "`", "\t", "\n", "\r", ";", "|", "&", "<", ">",
               "$(", "$'", "''", "\"\"", "é", "世"]
        for _ in 0..<2000 {
            let count = rng.nextInt(upperBound: 41)
            var input = ""
            for _ in 0..<count {
                input += rng.nextElement(alphabet)
            }
            expectParity(input)
        }
    }
}

/// Random lexemes over a metachar-safe alphabet: no quote characters, so
/// double-quoting words with whitespace re-emits them losslessly. May
/// include interior spaces and empty words to exercise quoting on re-emit.
private func randomLexemes(rng: inout XorShift64) -> [String] {
    let pieces = ["a", "Z", "0", "-", "_", ".", "/", "=", ":", ",", "+", "@", "%",
                  "$", "(", ")", "`", ";", "|", "&", "<", ">", "{", "}", "é", "世"]
    let count = rng.nextInt(upperBound: 7)
    return (0..<count).map { _ in
        if rng.nextInt(upperBound: 20) == 0 { return "" }
        var word = ""
        for _ in 0..<rng.nextInt(upperBound: 8) {
            word += rng.nextElement(pieces)
            if rng.nextInt(upperBound: 12) == 0 { word += " " }
        }
        return word.trimmingCharacters(in: [" "])
    }
}

/// Emits `lexemes` as shell text, tracking the expected token stream:
/// one `"\n"` token wherever a separator run contained a newline (runs
/// collapse, matching the tokenizer), plus the literal lexemes.
private func emit(
    lexemes: [String],
    rng: inout XorShift64,
    trailingSeparator: Bool,
    newlineSeparators: Bool = true
) -> (text: String, expected: [String]) {
    // The re-emit pass joins with spaces/tabs only: newline separators would
    // inject structural tokens absent from the input stream.
    let separators = newlineSeparators
        ? [" ", "  ", "\t", "\n", " \n ", "\r\n", "\r", " \t "]
        : [" ", "  ", "\t", " \t "]
    var out = ""
    var expected: [String] = []
    for (index, lexeme) in lexemes.enumerated() {
        if index > 0 {
            let separator = rng.nextElement(separators)
            out += separator
            if separatorHasNewline(separator) {
                expected.append("\n")
            }
        }
        out += quoteIfNeeded(lexeme)
        expected.append(lexeme)
    }
    if trailingSeparator, rng.nextInt(upperBound: 4) == 0 {
        let separator = rng.nextElement(separators)
        out += separator
        if separatorHasNewline(separator) {
            expected.append("\n")
        }
    }
    return (out, expected)
}

/// Scalar-based: `"\r\n"` is one `Character`, so grapheme iteration and
/// the `Character` overload of `contains` both miss it.
private func separatorHasNewline(_ separator: String) -> Bool {
    separator.unicodeScalars.contains("\n") || separator.unicodeScalars.contains("\r")
}

private func quoteIfNeeded(_ lexeme: String) -> String {
    if lexeme == "\n" { return "\n" }
    if lexeme.isEmpty { return "\"\"" }
    // Unterminated backtick / $() captures swallow following separators when
    // raw, so force quotes (lexemes never contain `"`, keeping this lossless).
    if lexeme.contains("`") || lexeme.contains("$(") { return "\"\(lexeme)\"" }
    if lexeme.contains(where: { $0.isWhitespace }) { return "\"\(lexeme)\"" }
    return lexeme
}
