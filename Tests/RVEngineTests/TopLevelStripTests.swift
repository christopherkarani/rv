import Testing
@testable import RVEngine

@Suite("Top-level piece map + per-segment prefix strip (Step 8B P10e1)")
struct TopLevelStripTests {
    @Test func map_identityRejoinsByteForByte() {
        let nasty = [
            "a  &&   b",
            "  a && b  ",
            "a\t||\tb",
            "a;b;c",
            "a | b | c",
            "echo a >|/tmp/x",
            "a >|| b",
            "FOO='a b' git push && X=1  ls",
            "echo $(a; b) && true",
            "(a && b) || c",
            "a & b &",
            "a\nb\rc",
            "   ",
            "",
            "a && && b",
            "&& a",
            "a &&",
            "echo \"a|b\" && echo 'c;d'",
            "a>&1 | b",
            "2>|b",
        ]
        for text in nasty {
            #expect(
                mapTopLevelPieces(text) { $0 } == text,
                "identity rejoin must be byte-exact: \(text.debugDescription)"
            )
        }
    }

    @Test func map_noclobberBarIsNotAPipe() {
        // `>|` must survive as one piece so the redirect is evaluated.
        var seen: [String] = []
        let out = mapTopLevelPieces("echo a >|/tmp/x") {
            seen.append($0)
            return $0
        }
        #expect(seen == ["echo a >|/tmp/x"])
        #expect(out == "echo a >|/tmp/x")
    }

    @Test func strip_allSegmentsQuotedValues() {
        // The tokenizer decodes `FOO='a b'` to the unquoted lexeme `FOO=a b`,
        // so only a raw-text per-segment strip can remove the whole prefix.
        #expect(
            ShellPipeline.stripAssignmentPrefixesAllSegments("true && FOO='a b' git push")
                == "true && git push"
        )
        #expect(
            ShellPipeline.stripAssignmentPrefixesAllSegments("FOO='a b' git push")
                == "git push"
        )
        #expect(
            ShellPipeline.stripAssignmentPrefixesAllSegments("A=1 b && C='x y' d || E=2 f")
                == "b && d || f"
        )
    }

    @Test func strip_allSegmentsPreservesGaps() {
        #expect(
            ShellPipeline.stripAssignmentPrefixesAllSegments("true  &&   FOO=1  git push")
                == "true  &&   git push"
        )
        #expect(
            ShellPipeline.stripAssignmentPrefixesAllSegments("  FOO=1 a  ;  BAR=2 b  ")
                == "  a  ;  b  "
        )
    }

    @Test func strip_allSegmentsSubstitutionRewritePerPiece() {
        // Substitution prefixes rewrite to `VALUE ; TAIL` in every piece, so
        // both the substitution and the tail evaluate downstream.
        #expect(
            ShellPipeline.stripAssignmentPrefixesAllSegments("true && X=$(:) git push")
                == "true && $(:) ; git push"
        )
        #expect(
            ShellPipeline.stripAssignmentPrefixesAllSegments("A=$(a) b; C=$(c) d")
                == "$(a) ; b; $(c) ; d"
        )
    }

    @Test func strip_nonAssignmentsUntouched() {
        #expect(
            ShellPipeline.stripAssignmentPrefixesAllSegments("echo a=b && git push")
                == "echo a=b && git push"
        )
        #expect(
            ShellPipeline.stripAssignmentPrefixesAllSegments("./run.sh && make test")
                == "./run.sh && make test"
        )
    }
}
