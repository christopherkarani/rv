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
        // The scan keeps classifying after `--`: most consumers split
        // there, `clean` skips it, push-family rejects it (T3b).
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
            ShellPipeline.scanFlags(argv, values: spec) == [
                .long(name: "date", value: "2024-01-01"),
                .positional("file"),
            ]
        )
    }

    @Test func scan_bareValueLongConsumesNextWord() {
        let spec = FlagValueSpec(valueLongs: ["source"])
        let argv = Argv(program: "git", args: ["--source", "HEAD", "file"])
        #expect(
            ShellPipeline.scanFlags(argv, values: spec) == [
                .long(name: "source", value: "HEAD"),
                .positional("file"),
            ]
        )
    }

    @Test func scan_clusterConsumesOneWordPerCluster() {
        // touch -td: both letters arm the expect-flag, one word consumed.
        let spec = FlagValueSpec(valueShorts: ["t", "d"])
        let argv = Argv(program: "touch", args: ["-td", "2024-01-01", "file"])
        #expect(
            ShellPipeline.scanFlags(argv, values: spec) == [
                .shorts(letters: ["t", "d"], value: "2024-01-01"),
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
            ShellPipeline.scanFlags(argv, values: spec) == [
                .shorts(letters: ["t"], value: "--"),
                .positional("file"),
            ]
        )
        // ... and `-t -d` consumes the flag-looking word too.
        let argv2 = Argv(program: "touch", args: ["-t", "-d", "file"])
        #expect(
            ShellPipeline.scanFlags(argv2, values: spec) == [
                .shorts(letters: ["t"], value: "-d"),
                .positional("file"),
            ]
        )
    }

    @Test func scan_missingValueDangles() {
        let longSpec = FlagValueSpec(valueLongs: ["source"])
        #expect(
            ShellPipeline.scanFlags(Argv(program: "git", args: ["--source"]), values: longSpec)
                == [.dangling(flag: "--source")]
        )
        let shortSpec = FlagValueSpec(valueShorts: ["b"], rejectsDashValues: true)
        #expect(
            ShellPipeline.scanFlags(Argv(program: "git", args: ["-b"]), values: shortSpec)
                == [.dangling(flag: "-b")]
        )
    }

    @Test func scan_rejectDashValues() {
        // checkout -b / switch -c reject dash-led names; the rejected word
        // is classified normally next (consumers fail at the dangling flag).
        let spec = FlagValueSpec(valueShorts: ["b", "B"], rejectsDashValues: true)
        let argv = Argv(program: "git", args: ["-b", "-f"])
        #expect(
            ShellPipeline.scanFlags(argv, values: spec) == [
                .dangling(flag: "-b"),
                .shorts(letters: ["f"], value: nil),
            ]
        )
        let ok = Argv(program: "git", args: ["-qb", "main"])
        #expect(
            ShellPipeline.scanFlags(ok, values: spec) == [
                .shorts(letters: ["q", "b"], value: "main")
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
}

// MARK: - Adapter equivalence: legacy helpers agree with the grammar

@Suite struct ShellPipelineFlagAdapterTests {
    @Test(arguments: adapterBattery)
    func adapter_matchesGrammar(word: String) {
        let classified = FlagToken.classify(word)
        if case .shorts(let letters, _) = classified {
            #expect(clusteredShorts(word) == letters)
        } else {
            #expect(clusteredShorts(word) == nil)
        }
        for long in ["--source", "--branch", "--repo"] {
            let expected: String? = {
                guard case .long(let name, let value) = classified,
                    "--" + name == long,
                    let value,
                    value.isEmpty == false
                else { return nil }
                return value
            }()
            #expect(gitAttachedValue(word, long: long) == expected)
        }
    }
}

private let adapterBattery: [String] = [
    "-abc", "--abc", "-", "-a=b", "abc", "", "--source=HEAD", "--source=",
    "--source", "--other=x", "-rf", "--", "-name", "--branch=main", "--=x",
]
