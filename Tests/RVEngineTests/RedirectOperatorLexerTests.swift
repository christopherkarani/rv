import Testing
import RVDomain
@testable import RVEngine

@Suite("Redirect operator lexer (R1)")
struct RedirectOperatorLexerTests {
    // MARK: - classify: one table, every spelling

    @Test func classify_outputOperatorsBareAndFdPrefixed() {
        for op in [">", ">|", ">>", ">&", "&>", "&>>", "<>"] {
            #expect(RedirectOperatorLexer.classify(op) == .output)
            #expect(RedirectOperatorLexer.classify("2" + op) == .output || op.hasPrefix("&"))
        }
        #expect(RedirectOperatorLexer.classify("2>") == .output)
        #expect(RedirectOperatorLexer.classify("10>>") == .output)
        #expect(RedirectOperatorLexer.classify("2>&") == .output)
        #expect(RedirectOperatorLexer.classify("2<>") == .output)
    }

    @Test func classify_inputOperatorsBareAndFdPrefixed() {
        for op in ["<", "<<", "<<<", "<<-", "<&"] {
            #expect(RedirectOperatorLexer.classify(op) == .input)
            #expect(RedirectOperatorLexer.classify("2" + op) == .input)
        }
        #expect(RedirectOperatorLexer.classify("10<") == .input)
    }

    @Test func classify_excludesAmpLedWithFdDigits() {
        // Preserved from isRedirectOperator: `2&>` was never an operator.
        #expect(RedirectOperatorLexer.classify("2&>") == nil)
        #expect(RedirectOperatorLexer.classify("2&>>") == nil)
        #expect(RedirectOperatorLexer.classify("10&>") == nil)
    }

    @Test func classify_rejectsNonOperators() {
        for word in ["", "a", "2", ">2", ">&1", "2>&1", ">&-", "<&-", "a>b", ">>x", "2>err"] {
            #expect(RedirectOperatorLexer.classify(word) == nil)
        }
        // Non-ASCII digits are not fd digits (ASCII-gated, as before).
        #expect(RedirectOperatorLexer.classify("²>") == nil)
    }

    // MARK: - isFdDup: the exact four literals, structurally

    @Test func isFdDup_matchesFourLiteralsOnly() {
        #expect(RedirectOperatorLexer.isFdDup("2>&1"))
        #expect(RedirectOperatorLexer.isFdDup("1>&2"))
        #expect(RedirectOperatorLexer.isFdDup(">&1"))
        #expect(RedirectOperatorLexer.isFdDup(">&2"))
        // Self-dups were never fd dups.
        #expect(RedirectOperatorLexer.isFdDup("1>&1") == false)
        #expect(RedirectOperatorLexer.isFdDup("2>&2") == false)
        // Multi-digitfds, closes, input-dups, and out-of-range fds are not.
        for word in ["", ">&", ">&12", "10>&1", "2>&-", "1>&3", "2>&9", "3>&1", ">&3", "<&1", "2<&1"] {
            #expect(RedirectOperatorLexer.isFdDup(word) == false)
        }
    }

    // MARK: - attachedTarget: dup/close vs file readings

    @Test func attachedTarget_fileTargets() {
        #expect(RedirectOperatorLexer.attachedTarget(">>file") == "file")
        #expect(RedirectOperatorLexer.attachedTarget(">|file") == "file")
        #expect(RedirectOperatorLexer.attachedTarget("&>>file") == "file")
        #expect(RedirectOperatorLexer.attachedTarget(">&file") == "file")
        #expect(RedirectOperatorLexer.attachedTarget("&>log") == "log")
        #expect(RedirectOperatorLexer.attachedTarget("<>rw") == "rw")
        #expect(RedirectOperatorLexer.attachedTarget(">plain") == "plain")
        #expect(RedirectOperatorLexer.attachedTarget("2>err") == "err")
        #expect(RedirectOperatorLexer.attachedTarget("10>>log") == "log")
        #expect(RedirectOperatorLexer.attachedTarget("2<>rw") == "rw")
        #expect(RedirectOperatorLexer.attachedTarget(">>$FILE") == "$FILE")
        // `>&1b` duplicates to the FILE `1b`, not fd 1.
        #expect(RedirectOperatorLexer.attachedTarget(">&1b") == "1b")
        #expect(RedirectOperatorLexer.attachedTarget("2>&1b") == "1b")
    }

    @Test func attachedTarget_dupCloseReadsNil() {
        for word in ["2>&1", ">&-", ">&2", "1>&3", "2>&9", "<&-", "&>&1", "&>&x"] {
            #expect(RedirectOperatorLexer.attachedTarget(word) == nil)
        }
    }

    @Test func attachedTarget_preservedAsymmetries() {
        // `&>` has no numeric check: numeric rests ARE files here ...
        #expect(RedirectOperatorLexer.attachedTarget("&>2") == "2")
        #expect(RedirectOperatorLexer.attachedTarget("&>-") == "-")
        // ... while `>&` dups numeric rests and closes `-`.
        #expect(RedirectOperatorLexer.attachedTarget(">&2") == nil)
        #expect(RedirectOperatorLexer.attachedTarget(">&-") == nil)
        // `>>` has no `&` check: the rest is the target verbatim ...
        #expect(RedirectOperatorLexer.attachedTarget(">>&1") == "&1")
        // ... except after fd digits, where the old fd arm refused `&` rests.
        #expect(RedirectOperatorLexer.attachedTarget("2>>&1") == nil)
        #expect(RedirectOperatorLexer.attachedTarget("10>>&x") == nil)
        // ... while `>&`/`&>` refuse `&`-led rests.
        #expect(RedirectOperatorLexer.attachedTarget(">&&x") == nil)
        #expect(RedirectOperatorLexer.attachedTarget("&>&x") == nil)
        // Bare `>` names even numeric files; `>&` with a numeric rest dups.
        #expect(RedirectOperatorLexer.attachedTarget(">2") == "2")
        #expect(RedirectOperatorLexer.attachedTarget(">-") == "-")
    }

    @Test func attachedTarget_bareOperatorsNameNothing() {
        // Dead-quirk normalization: bare operators never reach the attached
        // reader (redirectTargets checks isRedirectOperator first), so they
        // read nil instead of the old fallback-arm scraps (`>>` read `>`).
        // No reachable path changes: attachedRedirectTarget is only called
        // for non-operator words.
        for word in [">>", ">|", "&>>", ">&", "&>", "<>", ">", "2>>", "2>|", "2>&", "2>"] {
            #expect(RedirectOperatorLexer.attachedTarget(word) == nil)
        }
    }

    @Test func attachedTarget_rejectsNonLeadingOperators() {
        for word in ["", "a>b", "2&>f", "2&>>f", "<f", "<<EOF", "a", "12", "$F"] {
            #expect(RedirectOperatorLexer.attachedTarget(word) == nil)
        }
    }

    // MARK: - splitPieces: gluing

    @Test func splitPieces_wordOpTarget() {
        #expect(RedirectOperatorLexer.splitPieces("b>/tmp/x") == ["b", ">", "/tmp/x"])
        #expect(RedirectOperatorLexer.splitPieces("a2>>b") == ["a", "2>>", "b"])
        #expect(RedirectOperatorLexer.splitPieces("a>/tmp/x>/tmp/y") == ["a", ">", "/tmp/x", ">", "/tmp/y"])
        #expect(RedirectOperatorLexer.splitPieces("a>&/tmp/f") == ["a", ">&", "/tmp/f"])
        #expect(RedirectOperatorLexer.splitPieces("a<>b") == ["a", "<>", "b"])
        #expect(RedirectOperatorLexer.splitPieces("a<<<b") == ["a", "<<<", "b"])
        #expect(RedirectOperatorLexer.splitPieces("a<<-EOF") == ["a", "<<-", "EOF"])
        #expect(RedirectOperatorLexer.splitPieces("a10>b") == ["a", "10>", "b"])
    }

    @Test func splitPieces_dupCloseGluing() {
        #expect(RedirectOperatorLexer.splitPieces("2>&1") == ["2>&1"])
        #expect(RedirectOperatorLexer.splitPieces("a2>&1") == ["a", "2>&1"])
        #expect(RedirectOperatorLexer.splitPieces(">&-") == [">&-"])
        #expect(RedirectOperatorLexer.splitPieces("a<&-") == ["a", "<&-"])
        #expect(RedirectOperatorLexer.splitPieces("a>&1b") == ["a", ">&", "1b"])
    }

    @Test func splitPieces_preservedEdgeReadings() {
        // `&>` is not a split atom: the `>` splits and the `&` stays left.
        #expect(RedirectOperatorLexer.splitPieces("a&>b") == ["a&", ">", "b"])
        // Backslash-escaped metachars never split, trailing backslash kept.
        #expect(RedirectOperatorLexer.splitPieces(#"a\>b"#) == [#"a\>b"#])
        #expect(RedirectOperatorLexer.splitPieces(#"a\"#) == [#"a\"#])
        #expect(RedirectOperatorLexer.splitPieces("") == [""])
        #expect(RedirectOperatorLexer.splitPieces("plain") == ["plain"])
        #expect(RedirectOperatorLexer.splitPieces("a2<b") == ["a", "2<", "b"])
    }

    // MARK: - isAttachedRedirectWord + stripWriterRedirectWords policy

    @Test func attachedWord_leadingOperatorWords() {
        for word in [">f", ">>f", ">&f", "&>f", "&>>f", "<f", "<<EOF", "<<-EOF", "<<<x", "<>f", "2>f", "10>>f", "2<f"] {
            #expect(RedirectOperatorLexer.isAttachedRedirectWord(word))
        }
        // Standalone separators also read attached (both old arms dropped
        // exactly one word, so the readings coincide).
        for word in ["<", "<<", "<<-", "<<<", "0<", "1<", "2<", ">&", "<&", "2>&1", ">&-", "<&-"] {
            #expect(RedirectOperatorLexer.isAttachedRedirectWord(word))
        }
    }

    @Test func attachedWord_dupOperatorsAnywhere() {
        #expect(RedirectOperatorLexer.isAttachedRedirectWord("a>&b"))
        #expect(RedirectOperatorLexer.isAttachedRedirectWord("a<&b"))
        #expect(RedirectOperatorLexer.isAttachedRedirectWord("x>&12y"))
    }

    @Test func attachedWord_preservedNonMatches() {
        // `&>` after fd digits is not redirect syntax (kept as an operand).
        #expect(RedirectOperatorLexer.isAttachedRedirectWord("2&>f") == false)
        // Mid-word operators without a dup do not drop whole: the writer
        // stripper never split mid-word words.
        #expect(RedirectOperatorLexer.isAttachedRedirectWord("a>b") == false)
        #expect(RedirectOperatorLexer.isAttachedRedirectWord("plain") == false)
        #expect(RedirectOperatorLexer.isAttachedRedirectWord("") == false)
        // Non-ASCII digits count as fd digits here (plain `.isNumber`,
        // unlike the ASCII-gated readers) — preserved quirk.
        #expect(RedirectOperatorLexer.isAttachedRedirectWord("²>"))
    }

    @Test func stripWriterRedirectWords_policyEndToEnd() {
        // Output operators drop WITH their target (the union re-adds it).
        #expect(stripWriterRedirectWords(["a", ">", "b"]) == ["a"])
        #expect(stripWriterRedirectWords(["a", "2>>", "b"]) == ["a"])
        // Input/heredoc operators drop WITHOUT target-eating.
        #expect(stripWriterRedirectWords(["a", "<", "b"]) == ["a", "b"])
        #expect(stripWriterRedirectWords(["a", "<<", "EOF"]) == ["a", "EOF"])
        // Attached input words and fd dups/closes drop whole.
        #expect(stripWriterRedirectWords(["<f"]) == [])
        #expect(stripWriterRedirectWords(["2>&1"]) == [])
        #expect(stripWriterRedirectWords(["a", ">&-", "b"]) == ["a", "b"])
        // Non-redirect words survive, including `2&>`-led and mid-word forms.
        #expect(stripWriterRedirectWords(["2&>f"]) == ["2&>f"])
        #expect(stripWriterRedirectWords(["a>b"]) == ["a>b"])
    }
}
