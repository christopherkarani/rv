import Testing
@testable import RVEngine

// MARK: - FlagToken classification goldens

@Suite struct ShellPipelineFlagTokenTests {
    @Test(arguments: classifyGoldens)
    func classify_golden(word: String, expected: FlagToken) {
        #expect(FlagToken.classify(word) == expected)
    }

    @Test(arguments: singleDashWordGoldens)
    func singleDashWord_golden(word: String, expected: String?) {
        #expect(FlagToken.classify(word).singleDashWord == expected)
    }
}

private let classifyGoldens: [(word: String, expected: FlagToken)] = [
    ("--", .terminator),
    ("-", .loneDash),
    ("--force", .long(name: "force", value: nil)),
    ("--source=HEAD", .long(name: "source", value: "HEAD")),
    // Empty attached value stays "" (never nil): --source= fails today,
    // --force-with-lease= passes, so both halves are load-bearing.
    ("--source=", .long(name: "source", value: "")),
    ("--a=b=c", .long(name: "a", value: "b=c")),
    ("---", .long(name: "-", value: nil)),
    ("--=", .long(name: "", value: "")),
    ("-rf", .shorts(letters: ["r", "f"], value: nil)),
    ("-f", .shorts(letters: ["f"], value: nil)),
    ("-name", .shorts(letters: ["n", "a", "m", "e"], value: nil)),
    ("-m=x", .shortEquals(name: "m", value: "x")),
    ("-=x", .shortEquals(name: "", value: "x")),
    ("foo", .positional("foo")),
    ("", .positional("")),
    ("- hou", .shorts(letters: [" ", "h", "o", "u"], value: nil)),
]

private let singleDashWordGoldens: [(word: String, expected: String?)] = [
    ("-name", "name"),
    ("-iname", "iname"),
    ("-ipath", "ipath"),
    ("-f", nil),
    ("--force", nil),
    ("--", nil),
    ("-", nil),
    ("-m=x", nil),
    ("plain", nil),
]

// MARK: - scanFlags goldens: terminator + value-taking flags

@Suite struct ShellPipelineFlagScanTests {
    @Test func scan_terminatorIsFirstClassEvent() {
        // The flat scan keeps classifying after `--`: split-consumers
        // stop via splitFlagTerminator, push/branch/tag/stash reject it.
        let argv = Argv(program: "rm", args: ["-rf", "--", "-foo", "bar"])
        #expect(
            ShellPipeline.scanFlags(argv) == [
                .shorts(letters: ["r", "f"], value: nil),
                .terminator,
                .shorts(letters: ["f", "o", "o"], value: nil),
                .positional("bar"),
            ]
        )
    }

    @Test func scan_attachedLongNeverConsumes() {
        let spec = FlagValueSpec(valueLongs: ["date"])
        let argv = Argv(program: "touch", args: ["--date=2024-01-01", "file"])
        #expect(
            ShellPipeline.scanFlags(argv, valueSpec: spec) == [
                .long(name: "date", value: "2024-01-01"),
                .positional("file"),
            ]
        )
        // An empty attached value still never consumes: legacy touch skips
        // `--date=` without arming its expect flag.
        let empty = Argv(program: "touch", args: ["--date=", "file"])
        #expect(
            ShellPipeline.scanFlags(empty, valueSpec: spec) == [
                .long(name: "date", value: ""),
                .positional("file"),
            ]
        )
    }

    @Test func scan_bareValueLongConsumesNextWord() {
        let spec = FlagValueSpec(valueLongs: ["source"])
        let argv = Argv(program: "git", args: ["--source", "HEAD", "file"])
        #expect(
            ShellPipeline.scanFlags(argv, valueSpec: spec) == [
                .long(name: "source", value: "HEAD"),
                .positional("file"),
            ]
        )
    }

    @Test func scan_clusterConsumesOneWordPerCluster() {
        // getopt reads left to right: the first taker consumes the rest of
        // its own cluster (`-td` reads value `d`), and only a bare taker
        // consumes the next word (`-t` alone reads `2024-01-01`).
        let spec = FlagValueSpec(valueShorts: ["t", "d"])
        let argv = Argv(program: "touch", args: ["-td", "2024-01-01", "file"])
        #expect(
            ShellPipeline.scanFlags(argv, valueSpec: spec) == [
                .shorts(letters: ["t"], value: "d"),
                .positional("2024-01-01"),
                .positional("file"),
            ]
        )
        let bare = Argv(program: "touch", args: ["-t", "2024-01-01", "file"])
        #expect(
            ShellPipeline.scanFlags(bare, valueSpec: spec) == [
                .shorts(letters: ["t"], value: "2024-01-01"),
                .positional("file"),
            ]
        )
    }

    @Test func scan_shortEqualsNeverConsumes() {
        // getopt reads `-t=x` as value `=x` when `t` takes a value; without
        // a taker the word stays `.shortEquals` (the tool errors on `=`).
        let spec = FlagValueSpec(valueShorts: ["t"])
        let argv = Argv(program: "touch", args: ["-t=x", "file"])
        #expect(
            ShellPipeline.scanFlags(argv, valueSpec: spec) == [
                .shorts(letters: ["t"], value: "=x"),
                .positional("file"),
            ]
        )
        let bare = Argv(program: "touch", args: ["-v=x", "file"])
        #expect(
            ShellPipeline.scanFlags(bare, valueSpec: spec) == [
                .shortEquals(name: "v", value: "x"),
                .positional("file"),
            ]
        )
    }

    @Test func scan_pendingValueTakesNextWordVerbatim() {
        // Legacy loops check the pending flag before the terminator/flag
        // tests, so `-t --` consumes `--` as the value.
        let spec = FlagValueSpec(valueShorts: ["t", "d"])
        let argv = Argv(program: "touch", args: ["-t", "--", "file"])
        #expect(
            ShellPipeline.scanFlags(argv, valueSpec: spec) == [
                .shorts(letters: ["t"], value: "--"),
                .positional("file"),
            ]
        )
        // ... and `-t -d` consumes the flag-looking word too.
        let argv2 = Argv(program: "touch", args: ["-t", "-d", "file"])
        #expect(
            ShellPipeline.scanFlags(argv2, valueSpec: spec) == [
                .shorts(letters: ["t"], value: "-d"),
                .positional("file"),
            ]
        )
    }

    @Test func scan_missingValueDangles() {
        let longSpec = FlagValueSpec(valueLongs: ["source"])
        #expect(
            ShellPipeline.scanFlags(Argv(program: "git", args: ["--source"]), valueSpec: longSpec)
                == [.dangling(flag: "--source")]
        )
        let shortSpec = FlagValueSpec(valueShorts: ["b"], rejectsDashValues: true)
        #expect(
            ShellPipeline.scanFlags(Argv(program: "git", args: ["-b"]), valueSpec: shortSpec)
                == [.dangling(flag: "-b")]
        )
        // End-of-argv dangles under the default spec too: legacy touch
        // `-t` with no following word fails the parse.
        #expect(
            ShellPipeline.scanFlags(
                Argv(program: "touch", args: ["-t"]),
                valueSpec: FlagValueSpec(valueShorts: ["t"])
            ) == [.dangling(flag: "-t")]
        )
    }

    @Test func scan_rejectDashValues() {
        // checkout -b / switch -c reject dash-led names; the rejected word
        // is classified normally next (consumers fail at the dangling flag).
        let spec = FlagValueSpec(valueShorts: ["b", "B"], rejectsDashValues: true)
        let argv = Argv(program: "git", args: ["-b", "-f"])
        #expect(
            ShellPipeline.scanFlags(argv, valueSpec: spec) == [
                .dangling(flag: "-b"),
                .shorts(letters: ["f"], value: nil),
            ]
        )
        let ok = Argv(program: "git", args: ["-qb", "main"])
        #expect(
            ShellPipeline.scanFlags(ok, valueSpec: spec) == [
                .shorts(letters: ["q", "b"], value: "main")
            ]
        )
        // Long-form branch takers reject dash-led values the same way.
        let longSpec = FlagValueSpec(valueLongs: ["branch"], rejectsDashValues: true)
        #expect(
            ShellPipeline.scanFlags(
                Argv(program: "git", args: ["--branch", "-f"]), valueSpec: longSpec
            ) == [
                .dangling(flag: "--branch"),
                .shorts(letters: ["f"], value: nil),
            ]
        )
        // `--` and lone `-` are dash-led too, so they are rejected and
        // classified normally next.
        #expect(
            ShellPipeline.scanFlags(
                Argv(program: "git", args: ["--branch", "--"]), valueSpec: longSpec
            ) == [
                .dangling(flag: "--branch"),
                .terminator,
            ]
        )
        #expect(
            ShellPipeline.scanFlags(
                Argv(program: "git", args: ["-b", "-"]), valueSpec: spec
            ) == [
                .dangling(flag: "-b"),
                .loneDash,
            ]
        )
    }

    @Test func scan_nonValueFlagsPassThrough() {
        let argv = Argv(program: "rm", args: ["-rf", "--force", "-", "-x=y", "f"])
        #expect(
            ShellPipeline.scanFlags(argv) == [
                .shorts(letters: ["r", "f"], value: nil),
                .long(name: "force", value: nil),
                .loneDash,
                .shortEquals(name: "x", value: "y"),
                .positional("f"),
            ]
        )
    }

    @Test func scan_longResolvesUniquePrefix() {
        let spec = FlagValueSpec(
            valueLongs: ["target-directory"],
            knownLongs: ["force", "no-clobber"]
        )
        // Unique prefixes resolve (and consume when value-taking).
        let argv = Argv(
            program: "mv",
            args: ["--targ", "dir", "--forc", "--no-c", "a"]
        )
        #expect(
            ShellPipeline.scanFlags(argv, valueSpec: spec) == [
                .long(name: "target-directory", value: "dir"),
                .long(name: "force", value: nil),
                .long(name: "no-clobber", value: nil),
                .positional("a"),
            ]
        )
        // Ambiguous and unknown spellings stay unresolved (the tool errors).
        #expect(spec.resolveLong("no-") == "no-clobber")
        #expect(spec.resolveLong("t") == "target-directory")
        #expect(spec.resolveLong("x") == "x")
        let both = FlagValueSpec(knownLongs: ["dir", "directory"])
        #expect(both.resolveLong("d") == "d")
        #expect(both.resolveLong("di") == "di")
        #expect(both.resolveLong("dir") == "dir")
    }

    @Test func scan_attachedShortValueIsSelfContained() {
        // `-tSTAMP` reads `STAMP` without touching `--` or the next word.
        let spec = FlagValueSpec(valueShorts: ["t"])
        let argv = Argv(program: "touch", args: ["-tSTAMP", "--", "file"])
        #expect(
            ShellPipeline.scanFlags(argv, valueSpec: spec) == [
                .shorts(letters: ["t"], value: "STAMP"),
                .terminator,
                .positional("file"),
            ]
        )
        // Bare letters before the taker are kept as flags.
        let clustered = Argv(program: "touch", args: ["-vtSTAMP", "file"])
        #expect(
            ShellPipeline.scanFlags(clustered, valueSpec: spec) == [
                .shorts(letters: ["v", "t"], value: "STAMP"),
                .positional("file"),
            ]
        )
    }
}

// MARK: - splitFlagTerminator goldens: pending-aware `--` stop

@Suite struct ShellPipelineSplitTerminatorTests {
    @Test func split_noTerminator_returnsAllEventsAndEmptyRest() {
        let (flags, rest) = ShellPipeline.splitFlagTerminator(
            Argv(program: "rm", args: ["-rf", "f"])
        )
        #expect(flags == [.shorts(letters: ["r", "f"], value: nil), .positional("f")])
        #expect(rest == [])
    }

    @Test func split_stopsAtTerminator_restVerbatim() {
        // Same argv as scan_terminatorIsFirstClassEvent: the flat scan
        // keeps classifying past `--`, the stopping scan cuts there.
        let (flags, rest) = ShellPipeline.splitFlagTerminator(
            Argv(program: "rm", args: ["-rf", "--", "-foo", "bar"])
        )
        #expect(flags == [.shorts(letters: ["r", "f"], value: nil)])
        #expect(rest == ["-foo", "bar"])
    }

    @Test func split_valueTaking_stopsAtTrueTerminator() {
        let spec = FlagValueSpec(valueLongs: ["size"])
        let (flags, rest) = ShellPipeline.splitFlagTerminator(
            Argv(program: "truncate", args: ["--", "--size", "10", "f"]),
            values: spec
        )
        #expect(flags.isEmpty)
        #expect(rest == ["--size", "10", "f"])
    }

    @Test func split_pendingValueConsumesDashDash() {
        // The consumed `--` is a value, not a terminator: no cut, so the
        // trailing positional stays a head event and rest is empty.
        let longSpec = FlagValueSpec(valueLongs: ["size"])
        let (longFlags, longRest) = ShellPipeline.splitFlagTerminator(
            Argv(program: "truncate", args: ["--size", "--", "file"]),
            values: longSpec
        )
        #expect(longFlags == [.long(name: "size", value: "--"), .positional("file")])
        #expect(longRest == [])
        let shortSpec = FlagValueSpec(valueShorts: ["s"])
        let (shortFlags, shortRest) = ShellPipeline.splitFlagTerminator(
            Argv(program: "truncate", args: ["-s", "--", "file"]),
            values: shortSpec
        )
        #expect(shortFlags == [.shorts(letters: ["s"], value: "--"), .positional("file")])
        #expect(shortRest == [])
    }

    @Test func split_consumedTerminator_secondDashDashStops() {
        let spec = FlagValueSpec(valueLongs: ["size"])
        let (flags, rest) = ShellPipeline.splitFlagTerminator(
            Argv(program: "truncate", args: ["--size", "--", "--", "x"]),
            values: spec
        )
        #expect(flags == [.long(name: "size", value: "--")])
        #expect(rest == ["x"])
    }

    @Test func split_rejectsDashValues_danglingThenTerminator() {
        // checkout-style spec: `-b` dangles on `--`, and the unconsumed
        // `--` still terminates.
        let spec = FlagValueSpec(valueShorts: ["b"], rejectsDashValues: true)
        let (flags, rest) = ShellPipeline.splitFlagTerminator(
            Argv(program: "checkout", args: ["-b", "--", "x"]),
            values: spec
        )
        #expect(flags == [.dangling(flag: "-b")])
        #expect(rest == ["x"])
    }

    @Test func split_valueFree_everyTokenShapeVerbatim() {
        let words = ["-", "--", "--long", "--long=value", "-xyz", "plain"]
        let (flags, rest) = ShellPipeline.splitFlagTerminator(
            Argv(program: "rm", args: ["--"] + words)
        )
        #expect(flags.isEmpty)
        #expect(rest == words)
    }
}
