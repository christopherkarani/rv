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

    @Test func strip_arrayAndSubscriptPrefixes() {
        // M-01: array/subscript prefixes execute the tail, so dispatch must
        // see past them (`A=(1) git push` allowed while policy saw `A=(1)`).
        #expect(ShellPipeline.stripLeadingAssignmentPrefixes("A=(1) git push") == "git push")
        #expect(ShellPipeline.stripLeadingAssignmentPrefixes("A=(1 2 3) git push") == "git push")
        #expect(ShellPipeline.stripLeadingAssignmentPrefixes("A=() git push") == "git push")
        #expect(ShellPipeline.stripLeadingAssignmentPrefixes("A+=(4) git push") == "git push")
        #expect(ShellPipeline.stripLeadingAssignmentPrefixes("A[0]=x git push") == "git push")
        #expect(ShellPipeline.stripLeadingAssignmentPrefixes("A[$i]=x git push") == "git push")
        #expect(ShellPipeline.stripLeadingAssignmentPrefixes("A[0]+=x git push") == "git push")
        #expect(
            ShellPipeline.stripLeadingAssignmentPrefixes("A=('a)b' \"c(d\") git push")
                == "git push"
        )
        #expect(
            ShellPipeline.stripAssignmentPrefixesAllSegments("true && A=(1) git push")
                == "true && git push"
        )
        // Unterminated compounds are a shell syntax error: nothing executes,
        // so declining the strip is sound.
        #expect(
            ShellPipeline.stripLeadingAssignmentPrefixes("A=(1 git push")
                == "A=(1 git push"
        )
        #expect(
            ShellPipeline.stripLeadingAssignmentPrefixes("A[0=x git push")
                == "A[0=x git push"
        )
        // Looks-like-assignment but is not: no `=`, no strip.
        #expect(ShellPipeline.stripLeadingAssignmentPrefixes("A[0] git push") == "A[0] git push")
        #expect(ShellPipeline.stripLeadingAssignmentPrefixes("[ -f x ]") == "[ -f x ]")
    }

    @Test func strip_arraySubstitutionValueRewrites() {
        // A substitution inside the compound still executes alongside the
        // tail, so it rewrites like a scalar substitution value.
        #expect(
            ShellPipeline.stripLeadingAssignmentPrefixes("A=($(a)) git push")
                == "($(a)) ; git push"
        )
        let (values, tail) = ShellPipeline.splitAssignmentPrefixValues("A=$(a) B=1 C=(x) git push")
        #expect(values == ["$(a)"])
        #expect(tail == "git push")
        let (plainValues, plainTail) = ShellPipeline.splitAssignmentPrefixValues("A=1 B=(x) git push")
        #expect(plainValues == [])
        #expect(plainTail == "git push")
    }
}
