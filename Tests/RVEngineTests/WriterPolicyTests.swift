import Testing
@testable import RVEngine

@Suite("Writer flag-scan policy over FlagToken events (W1)")
struct WriterPolicyTests {
    // cp-like verb: suffix/target-directory values, S conflicted.
    private static let cpLike = WriterVerbConfig(
        valueShorts: [],
        valueLongs: ["suffix", "target-directory"],
        bareShorts: ["r", "v", "S"],
        bareLongs: ["verbose", "archive"],
        conflictedShorts: ["S"]
    )
    private static let mValue = WriterVerbConfig(
        valueShorts: ["m"],
        valueLongs: ["suffix"],
        bareShorts: ["r", "v"],
        bareLongs: []
    )

    @Test func fold_unknownShortFailsAndStops() {
        let scan = WriterPolicy.fold(["-r", "-z", "a"], config: Self.cpLike)
        #expect(scan.failed)
        #expect(scan.bareShortHits == ["r"])
        #expect(scan.operands.isEmpty)
    }

    @Test func fold_unknownBareLongRecordsVerbatimCandidate() {
        // `--ver` is ambiguous (verbose + version), so both the unknown
        // `--frobnicate` and `--ver` record their verbatim neighbor.
        let scan = WriterPolicy.fold(
            ["--frobnicate", "--ver", "x"],
            config: Self.cpLike
        )
        #expect(scan.failed == false)
        #expect(scan.candidates == ["--ver", "x"])
        #expect(scan.bareLongHits.isEmpty)
    }

    @Test func fold_uniquePrefixResolvesToBare() {
        // `--verb` is unambiguous (verbose only; "verb" is not a prefix of
        // "version"), unlike `--ver` above.
        let scan = WriterPolicy.fold(["--verb", "a"], config: Self.cpLike)
        #expect(scan.failed == false)
        #expect(scan.bareLongHits == ["verbose"])
        #expect(scan.operands == ["a"])
        #expect(scan.candidates.isEmpty)
    }

    @Test func fold_unknownEqualsLongSkipped() {
        let scan = WriterPolicy.fold(["--frobnicate=x", "a"], config: Self.cpLike)
        #expect(scan.failed == false)
        #expect(scan.operands == ["a"])
        #expect(scan.candidates.isEmpty)
    }

    @Test func fold_noStarIsBare() {
        let scan = WriterPolicy.fold(["--no-clobber", "a"], config: Self.cpLike)
        #expect(scan.failed == false)
        #expect(scan.bareLongHits == ["no-clobber"])
        #expect(scan.operands == ["a"])
    }

    @Test func fold_conflictedShortTakesAttachedOnly() {
        let attached = WriterPolicy.fold(["-Sx", "a"], config: Self.cpLike)
        #expect(attached.failed == false)
        #expect(attached.flagValues == ["S": ["x"]])
        #expect(attached.operands == ["a"])
        // A separate `-S` stays bare: the next word is never consumed.
        let separate = WriterPolicy.fold(["-S", "x"], config: Self.cpLike)
        #expect(separate.failed == false)
        #expect(separate.bareShortHits == ["S"])
        #expect(separate.flagValues.isEmpty)
        #expect(separate.operands == ["x"])
        // First taker wins: `-Sr` reads suffix `r`, not bare `r`.
        let rest = WriterPolicy.fold(["-Sr", "a"], config: Self.cpLike)
        #expect(rest.failed == false)
        #expect(rest.flagValues == ["S": ["r"]])
        #expect(rest.bareShortHits.isEmpty)
    }

    @Test func fold_valueShortConsumesAttachedOrNext() {
        let attached = WriterPolicy.fold(["-mfoo", "a"], config: Self.mValue)
        #expect(attached.flagValues == ["m": ["foo"]])
        #expect(attached.operands == ["a"])
        let next = WriterPolicy.fold(["-m", "foo", "a"], config: Self.mValue)
        #expect(next.failed == false)
        #expect(next.flagValues == ["m": ["foo"]])
        #expect(next.operands == ["a"])
        #expect(WriterPolicy.fold(["-m"], config: Self.mValue).failed)
    }

    @Test func fold_valueLongResolvesUniquePrefix() {
        let scan = WriterPolicy.fold(["--suff", "bak", "a"], config: Self.mValue)
        #expect(scan.failed == false)
        #expect(scan.flagValues == ["suffix": ["bak"]])
        #expect(scan.operands == ["a"])
        let attached = WriterPolicy.fold(["--suffix=bak"], config: Self.mValue)
        #expect(attached.flagValues == ["suffix": ["bak"]])
        #expect(WriterPolicy.fold(["--suffix"], config: Self.mValue).failed)
    }

    @Test func fold_helpAndVersionExactOrUniquePrefix() {
        #expect(WriterPolicy.fold(["--help"], config: Self.cpLike).sawHelp)
        #expect(WriterPolicy.fold(["--version"], config: Self.cpLike).sawHelp)
        #expect(WriterPolicy.fold(["--he"], config: Self.cpLike).sawHelp)
        #expect(WriterPolicy.fold(["--help=x"], config: Self.cpLike).sawHelp)
        // Ambiguous `--ver` (verbose + version) is not help: candidate path.
        let ambiguous = WriterPolicy.fold(["--ver", "x"], config: Self.cpLike)
        #expect(ambiguous.sawHelp == false)
        #expect(ambiguous.candidates == ["x"])
    }

    @Test func fold_shortEqualsWalksLikeGetopt() {
        let valued = WriterPolicy.fold(["-m=x"], config: Self.mValue)
        #expect(valued.failed == false)
        #expect(valued.flagValues == ["m": ["=x"]])
        let cluster = WriterPolicy.fold(["-rvm=y"], config: Self.mValue)
        #expect(cluster.failed == false)
        #expect(cluster.flagValues == ["m": ["=y"]])
        #expect(cluster.bareShortHits == ["r", "v"])
        // A bare cluster with `=` fails like the tool.
        #expect(WriterPolicy.fold(["-rv=v"], config: Self.cpLike).failed)
    }

    @Test func fold_conflictedShortEquals() {
        let scan = WriterPolicy.fold(["-S=x"], config: Self.cpLike)
        #expect(scan.failed == false)
        #expect(scan.flagValues == ["S": ["=x"]])
        #expect(scan.operands.isEmpty)
    }

    @Test func fold_terminatorAndLoneDash() {
        let scan = WriterPolicy.fold(["a", "--", "-r"], config: Self.cpLike)
        #expect(scan.failed == false)
        #expect(scan.operands == ["a", "-r"])
        #expect(WriterPolicy.fold(["-", "a"], config: Self.cpLike).operands == ["-", "a"])
        // A pending value wins over the terminator, exactly like getopt.
        let pending = WriterPolicy.fold(["-m", "--", "a"], config: Self.mValue)
        #expect(pending.failed == false)
        #expect(pending.flagValues == ["m": ["--"]])
        #expect(pending.operands == ["a"])
    }

    @Test func resolveWriterLong_delegatesToSingleSite() {
        #expect(
            resolveWriterLong(
                "he",
                valueLongs: ["suffix", "target-directory"],
                bareLongs: ["verbose", "archive"]
            ) == "help"
        )
        #expect(
            resolveWriterLong(
                "ver",
                valueLongs: ["suffix"],
                bareLongs: ["verbose", "archive"]
            ) == "ver"
        )
        #expect(
            resolveWriterLong(
                "suff",
                valueLongs: ["suffix"],
                bareLongs: []
            ) == "suffix"
        )
        #expect(
            resolveWriterLong(
                "xyz",
                valueLongs: ["suffix"],
                bareLongs: ["archive"]
            ) == "xyz"
        )
        #expect(
            resolveWriterLong(
                "",
                valueLongs: ["suffix"],
                bareLongs: ["archive"]
            ) == ""
        )
    }

    @Test func attachedOnlyShorts_defaultEmpty() {
        #expect(FlagValueSpec().attachedOnlyShorts.isEmpty)
        #expect(FlagValueSpec.none.attachedOnlyShorts.isEmpty)
        let spec = FlagValueSpec(
            valueShorts: ["m"],
            attachedOnlyShorts: ["S"]
        )
        #expect(
            spec.splitShortValue(["S", "t"])
                == FlagValueSpec.ShortSplit(kept: ["S"], attached: "t")
        )
        #expect(spec.splitShortValue(["i"]) == nil)
        #expect(
            spec.shortEqualsValue(name: "S", value: "x")
                == .shorts(letters: ["S"], value: "=x")
        )
    }

    @Test func targetDirectory_preservedOverFlagMechanics() {
        let empty = extractTargetDirectory(["--target-directory=", "a"])
        #expect(empty.overrides == [""])
        #expect(empty.reduced == ["a"])
        let split = extractTargetDirectory(["-vt", "/tmp/x", "a"])
        #expect(split.overrides == ["/tmp/x"])
        #expect(split.reduced == ["-v", "a"])
        #expect(split.overrideAmbiguous == false)
        let dash = extractTargetDirectory(["-t", "--", "a"])
        #expect(dash.overrides == ["--"])
        #expect(dash.reduced == ["a"])
    }

    @Test func abbreviatedLongs_keepEvaluating() {
        #expect(parseCp(["--targ", "/tmp/x", "a", "b"])?.paths == ["/tmp/x"])
        #expect(parseCp(["--ver", "/tmp/c", "a", "b"])?.paths == ["/tmp/c", "b"])
        #expect(
            parseCp(["--frobnicate", "--verb", "x", "y"])?.paths == ["--verb", "y"]
        )
    }
}
