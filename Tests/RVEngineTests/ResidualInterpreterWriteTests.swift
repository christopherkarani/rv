import Testing
import RVDomain
@testable import RVEngine

/// Residual gaps after the round-2 bypass fixes: sed script commands that
/// execute, interpreter file writes, `awk -f` with an unknowable source.
@Suite("Residual gaps: sed scripts, interpreter writes, awk -f")
struct ResidualInterpreterWriteTests {
    // MARK: sed e command / s///e flag -> limited

    @Test func sedExecutionLimits() {
        expectLimited("sed 's/.*/rm -r ~/e' f", .sed)
        expectLimited("sed 'e rm -r ~' f", .sed)
        expectLimited("sed -n '1e id' f", .sed)
        expectLimited("sed -e 's/a/b/ge' f", .sed)
        expectLimited("sed -e p -e 'e id' f", .sed)
        expectLimited("sed --expression='e id' f", .sed)
        expectLimited("gsed 'e id' f", .sed)
        expectLimited("/usr/bin/sed 'e id' f", .sed)
        expectLimited("sed -i 's/.*/id/e' f", .sed)
    }

    @Test func sedTextThatMerelyContainsEIsNotExecution() {
        expectNotWrapper("sed -n '/e/p' f")
        expectNotWrapper("sed 's/e/x/' f")
        expectNotWrapper("sed 's/w/x/' f")
        expectNotWrapper("sed -n '/w/p' f")
        expectNotWrapper("sed 's/a/b/g;s/c/d/' f")
        expectNotWrapper("sed -n '/^e/,/^f/p' f")
        expectNotWrapper("sed '1d;$d' f")
        expectNotWrapper("sed 'y/abe/xyz/' f")
        expectNotWrapper("sed 'a hello e' f")
        expectNotWrapper("sed -n '/start/,/end/{/e/d;p}' f")
        expectNotWrapper("sed 's/x/y/gI' f")
        expectNotWrapper("sed -f script.sed f")
        expectNotWrapper("sed -n 1p f")
    }

    // MARK: sed script scanner

    @Test func sedScannerFindsWriteTargets() {
        #expect(sedScriptEffects("w /tmp/x").writeTargets == ["/tmp/x"])
        #expect(sedScriptEffects("W /tmp/x").writeTargets == ["/tmp/x"])
        #expect(sedScriptEffects("/a/w out.txt").writeTargets == ["out.txt"])
        #expect(sedScriptEffects("s/x/y/w ~/.bashrc").writeTargets == ["~/.bashrc"])
        #expect(sedScriptEffects("s/x/y/gw out").writeTargets == ["out"])
        #expect(sedScriptEffects("p;w a\nw b").writeTargets == ["a", "b"])
        #expect(sedScriptEffects("1,3{w out\n}").writeTargets == ["out"])
        #expect(sedScriptEffects("s/a\\/b/c/w out").writeTargets == ["out"])
        #expect(sedScriptEffects("w /dev/stdout").writeTargets.isEmpty)
    }

    @Test func sedScannerIgnoresWInTextPositions() {
        #expect(sedScriptEffects("/w/p").writeTargets.isEmpty)
        #expect(sedScriptEffects("s/w/x/").writeTargets.isEmpty)
        #expect(sedScriptEffects("s/x/w/g").writeTargets.isEmpty)
        #expect(sedScriptEffects("y/w/x/").writeTargets.isEmpty)
        #expect(sedScriptEffects("a w hello").writeTargets.isEmpty)
        #expect(sedScriptEffects("s/a/b/ # w file").writeTargets.isEmpty)
        #expect(sedScriptEffects("/a/!d").writeTargets.isEmpty)
        #expect(sedScriptEffects("bw;:w").writeTargets.isEmpty)
    }

    @Test func sedScannerFindsExecution() {
        #expect(sedScriptEffects("e").executes)
        #expect(sedScriptEffects("e id").executes)
        #expect(sedScriptEffects("$!e id").executes)
        #expect(sedScriptEffects("s/a/b/e").executes)
        #expect(sedScriptEffects("s/a/b/ge").executes)
        #expect(sedScriptEffects("p;e id").executes)
        #expect(sedScriptEffects("s/a/b/;e id").executes)
        #expect(sedScriptEffects("/e/p").executes == false)
        #expect(sedScriptEffects("s/e/e/").executes == false)
        #expect(sedScriptEffects("s/a/b/g").executes == false)
        #expect(sedScriptEffects("a e").executes == false)
    }

    // MARK: sed writes through the filesystem parser

    @Test func sedWCommandWritesItsTarget() {
        #expect(parseSed(["w /tmp/x", "f"])?.paths == ["/tmp/x"])
        #expect(parseSed(["-n", "w ~/.ssh/authorized_keys", "f"])?.paths == ["~/.ssh/authorized_keys"])
        #expect(parseSed(["s/x/y/w ~/.bashrc", "f"])?.paths == ["~/.bashrc"])
        #expect(parseSed(["-e", "p", "-e", "w out", "f"])?.paths == ["out"])
        #expect(parseSed(["-i", "w out", "f"])?.paths == ["f", "out"])
        #expect(parseSed(["-n", "/w/p", "f"]) == nil)
        #expect(parseSed(["s/w/x/", "f"]) == nil)
        #expect(parseSed(["-n", "1p", "~/.bashrc"]) == nil)
    }

    // MARK: perl -i

    @Test func perlInPlaceEditsItsFileOperands() {
        #expect(parsePerl(Argv(program: "perl", args: ["-pi", "-e", "s/a/b/", "~/.bashrc"]))?.paths == ["~/.bashrc"])
        #expect(parsePerl(Argv(program: "perl", args: ["-i", "-pe", "s/a/b/", "~/.bashrc"]))?.paths == ["~/.bashrc"])
        #expect(parsePerl(Argv(program: "perl", args: ["-i.bak", "-pe", "s/a/b/", "~/.bashrc"]))?.paths == ["~/.bashrc"])
        #expect(parsePerl(Argv(program: "perl", args: ["-p", "-i.bak", "-e", "1", "a", "b"]))?.paths == ["a", "b"])
        #expect(parsePerl(Argv(program: "perl", args: ["-pie", "s/a/b/", "x"]))?.paths == ["x"])
        #expect(parsePerl(Argv(program: "perl", args: ["-i", "script.pl", "x"]))?.paths == ["x"])
        #expect(parsePerl(Argv(program: "perl", args: ["-pe", "s/a/b/", "f"])) == nil)
        #expect(parsePerl(Argv(program: "perl", args: ["-ne", "print", "-i", "f"])) != nil)
        #expect(parsePerl(Argv(program: "perl", args: ["-e", "print 1"])) == nil)
        #expect(parsePerl(Argv(program: "perl", args: ["-e", "s/-i/x/", "f"])) == nil)
        #expect(parsePerl(Argv(program: "/usr/bin/perl", args: ["-lpi", "-e", "1", "/etc/hosts"]))?.paths == ["/etc/hosts"])
    }

    // MARK: write proxies (the matching view masks scripts, so the peel sees them)

    @Test func perlInPlaceAndSedScriptWritesPeelToTee() {
        expectComplete("perl -pi -e 's/a/b/' ~/.bashrc", inner: "tee -- ~/.bashrc", layers: [.perl])
        expectComplete("perl -i.bak -pe 's/a/b/' a b", inner: "tee -- a b", layers: [.perl])
        expectComplete("sed 'w /tmp/x' f", inner: "tee -- /tmp/x", layers: [.sed])
        expectComplete("sed -n 'w ~/.ssh/authorized_keys' f", inner: "tee -- ~/.ssh/authorized_keys", layers: [.sed])
        expectComplete("sed 's/x/y/w ~/.bashrc' f", inner: "tee -- ~/.bashrc", layers: [.sed])
        expectComplete("sed -i 'w out' f", inner: "tee -- f out", layers: [.sed])
        expectComplete("ls && perl -pi -e 1 ~/.bashrc", inner: "ls ; tee -- ~/.bashrc", layers: [.perl])
        expectNotWrapper("perl -pe 's/a/b/' f")
        expectNotWrapper("sed -n 1p ~/.bashrc")
        expectNotWrapper("sed 's/a/b/' ~/.bashrc")
        expectNotWrapper("sed -i 's/a/b/' ~/.bashrc")
    }

    @Test func proxiedWritesClassifyByRepository() {
        let repo = FilesystemAnalysisWorld.probed(
            FilesystemAnalysisContext(
                workingDirectory: WorkingDirectory(validating: "/repo"),
                repositoryRoot: RepositoryRoot(validating: "/repo"),
                homeDirectory: HomePath(validating: "/home/u")
            )
        )
        func scope(_ raw: String) -> FilesystemScope? {
            analyzeSemantics(ShellCommand(rawValue: raw), filesystemWorld: repo)
                .filesystemAction?.resources.filesystemScope
        }
        #expect(scope("perl -pi -e 's/a/b/' src/x.pl") == .insideRepository)
        #expect(scope("sed -n 'w out.txt' src/x") == .insideRepository)
        #expect(scope("sed -i 's/a/b/' src/x.swift") == .insideRepository)
        #expect(scope("perl -pi -e 's/a/b/' ~/.bashrc") != .insideRepository)
        #expect(scope("sed 'w /tmp/x' f") != .insideRepository)
    }

    // MARK: python / node / ruby file writes

    @Test func pythonFileWritesLimit() {
        expectLimited(#"python3 -c 'open("/Users/x/.bashrc","w").write("x")'"#, .python)
        expectLimited(#"python3 -c 'open("/Users/x/.bashrc", "a").write("x")'"#, .python)
        expectLimited(#"python3 -c 'open("f", "x")'"#, .python)
        expectLimited(#"python3 -c 'open("f", "r+")'"#, .python)
        expectLimited(#"python3 -c 'open("f", "wb")'"#, .python)
        expectLimited(#"python3 -c 'open("f", mode="w")'"#, .python)
        expectLimited(#"python3 -c 'open(os.path.expanduser("~/.bashrc"),"a")'"#, .python)
        expectLimited(#"python3 -c 'import io; io.open("f", "w")'"#, .python)
        expectLimited(#"python3 -c 'open("f", m)'"#, .python)
        expectLimited(#"python3 -c 'import os; os.open("f", os.O_WRONLY)'"#, .python)
        expectLimited(#"python3 -c 'from pathlib import Path; Path("f").open("w")'"#, .python)
        expectLimited(#"python3 -c 'from pathlib import Path; Path("f").touch()'"#, .python)
        expectLimited(#"python3 -c 'from pathlib import Path; Path("~/.ssh/authorized_keys").expanduser().write_text("x")'"#, .python)
    }

    @Test func pythonFileReadsStayAllowed() {
        expectNotWrapper(#"python3 -c 'print(open("f").read())'"#)
        expectNotWrapper(#"python3 -c 'print(open("f", "r").read())'"#)
        expectNotWrapper(#"python3 -c 'print(open("f", "rb").read())'"#)
        expectNotWrapper(#"python3 -c 'print(open("f", encoding="utf8").read())'"#)
        expectNotWrapper(#"python3 -c 'import json,sys; print(json.load(sys.stdin))'"#)
        expectNotWrapper(#"python3 -c 'print(sorted(open("f")))'"#)
        expectNotWrapper(#"python3 -c 'import webbrowser; webbrowser.open("u")'"#)
    }

    @Test func nodeFileWritesLimit() {
        expectLimited(#"node -e 'fs.writeFileSync("/x","y")'"#, .node)
        expectLimited(#"node -e 'require("fs").appendFileSync("/x","y")'"#, .node)
        expectLimited(#"node -e 'require("fs").writeFileSync("/x","y")'"#, .node)
        expectLimited(#"node -e 'fs.promises.writeFile("/x","y")'"#, .node)
        expectLimited(#"node -e 'const {writeFileSync}=require("fs"); writeFileSync("/x","y")'"#, .node)
        expectLimited(#"node -e 'require("fs").createWriteStream("/x")'"#, .node)
        expectLimited(#"node -e 'require("fs").openSync("/x","w")'"#, .node)
        expectLimited(#"node -e 'require("fs").copyFileSync("a","/x")'"#, .node)
    }

    @Test func nodeFileReadsStayAllowed() {
        expectNotWrapper(#"node -e 'console.log(require("fs").readFileSync("f","utf8"))'"#)
        expectNotWrapper(#"node -e 'console.log(1)'"#)
    }

    @Test func rubyFileWritesLimit() {
        expectLimited(#"ruby -e 'File.write("/x","y")'"#, .ruby)
        expectLimited(#"ruby -e 'File.open("/x","w")'"#, .ruby)
        expectLimited(#"ruby -e 'File.open("/x", "a") { |f| f.puts 1 }'"#, .ruby)
        expectLimited(#"ruby -e 'File.open("/x", mode: "w")'"#, .ruby)
        expectLimited(#"ruby -e 'File.new("/x", "w")'"#, .ruby)
        expectLimited(#"ruby -e 'open("/x", "w")'"#, .ruby)
        expectLimited(#"ruby -e 'File.open("/x", File::WRONLY)'"#, .ruby)
    }

    @Test func rubyFileReadsStayAllowed() {
        expectNotWrapper(#"ruby -e 'puts File.read("f")'"#)
        expectNotWrapper(#"ruby -e 'File.open("f") { |f| puts f.read }'"#)
        expectNotWrapper(#"ruby -e 'File.open("f", "r") { |f| puts f.read }'"#)
    }

    // MARK: awk -f with an unknowable source

    @Test func awkProgramFromProcessSubstitutionLimits() {
        expectLimited("awk -f <(echo x) f", .awk)
        expectLimited("awk -f $(mktemp) f", .awk)
        expectLimited("awk -f `mktemp` f", .awk)
        expectLimited("awk -f/dev/stdin f", .awk)
        expectLimited("awk -f /dev/fd/3 f", .awk)
        expectLimited("awk -f - f", .awk)
        expectNotWrapper("awk -f script.awk f")
        expectNotWrapper("awk -f tools/report.awk data.csv")
    }

    // MARK: eval false positives in the packs-only inline guard

    @Test func harmlessEvalDoesNotNeedAJudge() {
        for command in [
            #"python3 -c 'print(eval("1+1"))'"#,
            #"python3 -c 'print(eval("(2 + 3) * 4 / 2 - 1"))'"#,
            "perl -e 'print eval { 1 }'",
            "perl -e 'my $r = eval { 1 / 1 }; print $r'",
            "perl -e 'eval { die 1 }; print $@'",
        ] {
            #expect(InlineProgramGuard.requiresJudge(ShellCommand(rawValue: command)) == false, "\(command)")
        }
    }

    @Test func realEvalStillNeedsAJudge() {
        for command in [
            #"python3 -c 'print(eval(input()))'"#,
            #"python3 -c 'eval("__import__(\"os\")")'"#,
            #"python3 -c 'eval("1+x")'"#,
            #"python3 -c 'eval("1+1" + s)'"#,
            #"perl -e 'eval "system(1)"'"#,
            #"perl -e 'eval $x'"#,
            #"perl -e 'eval "1"'"#,
            #"perl -e 'eval { system("id") }'"#,
            #"ruby -e 'eval(x)'"#,
            #"node -e 'eval(process.argv[1])' x"#,
        ] {
            #expect(InlineProgramGuard.requiresJudge(ShellCommand(rawValue: command)), "\(command)")
        }
    }

    @Test func peelKeepsPerlStringEvalLimitedAndBlockEvalAllowed() {
        expectNotWrapper("perl -e 'print eval { 1 }'")
        expectLimited(#"perl -e 'print eval "1"'"#, .perl)
        expectLimited("perl -e 'eval $x'", .perl)
    }
}

private func expectLimited(_ raw: String, _ kind: WrapperKind) {
    let outcome = unwrapCommand(ShellCommand(rawValue: raw))
    guard case .limited(let layers) = outcome else {
        Issue.record("expected limited unwrap of \(raw), got \(outcome)")
        return
    }
    #expect(layers.contains(kind), "\(raw)")
}

private func expectNotWrapper(_ raw: String) {
    let outcome = unwrapCommand(ShellCommand(rawValue: raw))
    guard case .complete(let unwrapped) = outcome else {
        Issue.record("expected complete surface for \(raw), got \(outcome)")
        return
    }
    #expect(unwrapped.layers.isEmpty, "\(raw)")
}

private func expectComplete(_ raw: String, inner: String, layers: [WrapperKind]) {
    let outcome = unwrapCommand(ShellCommand(rawValue: raw))
    guard case .complete(let unwrapped) = outcome else {
        Issue.record("expected complete unwrap of \(raw), got \(outcome)")
        return
    }
    #expect(unwrapped.command.rawValue == inner, "\(raw)")
    #expect(unwrapped.layers == layers, "\(raw)")
}
