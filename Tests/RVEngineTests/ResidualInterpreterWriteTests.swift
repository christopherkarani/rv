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
        #expect(scope(#"python3 -c "import json; json.dump({}, open('out.json','w'))""#) == .insideRepository)
        #expect(scope(#"node -e "require('fs').writeFileSync('out.txt','y')""#) == .insideRepository)
        #expect(scope(#"python3 -c "open('/tmp/x','w')""#) != .insideRepository)
    }

    // MARK: python / node / ruby file writes

    @Test func pythonFileWritesLimit() {
        expectComplete(#"python3 -c 'open("/Users/x/.bashrc","w").write("x")'"#, inner: "tee -- /Users/x/.bashrc", layers: [.python])
        expectComplete(#"python3 -c 'open("/Users/x/.bashrc", "a").write("x")'"#, inner: "tee -- /Users/x/.bashrc", layers: [.python])
        expectComplete(#"python3 -c 'open("f", "x")'"#, inner: "tee -- f", layers: [.python])
        expectComplete(#"python3 -c 'open("f", "r+")'"#, inner: "tee -- f", layers: [.python])
        expectComplete(#"python3 -c 'open("f", "wb")'"#, inner: "tee -- f", layers: [.python])
        expectComplete(#"python3 -c 'open("f", mode="w")'"#, inner: "tee -- f", layers: [.python])
        expectLimited(#"python3 -c 'open(os.path.expanduser("~/.bashrc"),"a")'"#, .python)
        expectComplete(#"python3 -c 'import io; io.open("f", "w")'"#, inner: "tee -- f", layers: [.python])
        expectComplete(#"python3 -c 'import io; io.FileIO("/tmp/x", "w")'"#, inner: "tee -- /tmp/x", layers: [.python])
        expectLimited(#"python3 -c 'from pathlib import Path; p=Path("/tmp/x"); p.open("w")'"#, .python)
        expectLimited(#"python3 -c 'f=open; f("/tmp/x","w")'"#, .python)
        expectLimited(#"python3 -c '(open)("/tmp/x","w")'"#, .python)
        expectLimited(#"python3 -c 'open(*["/tmp/x","w"])'"#, .python)
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
        expectComplete(#"node -e 'fs.writeFileSync("/x","y")'"#, inner: "tee -- /x", layers: [.node])
        expectComplete(#"node -e 'require("fs").appendFileSync("/x","y")'"#, inner: "tee -- /x", layers: [.node])
        expectComplete(#"node -e 'require("fs").writeFileSync("/x","y")'"#, inner: "tee -- /x", layers: [.node])
        expectComplete(#"node -e 'fs.promises.writeFile("/x","y")'"#, inner: "tee -- /x", layers: [.node])
        expectComplete(#"node -e 'const {writeFileSync}=require("fs"); writeFileSync("/x","y")'"#, inner: "tee -- /x", layers: [.node])
        expectComplete(#"node -e 'require("fs").createWriteStream("/x")'"#, inner: "tee -- /x", layers: [.node])
        expectComplete(#"node -e 'require("fs").openSync("/x","w")'"#, inner: "tee -- /x", layers: [.node])
        expectComplete(#"node -e 'require("fs").copyFileSync("a","/x")'"#, inner: "tee -- /x", layers: [.node])
        expectLimited(#"node -e 'require("fs")["writeFileSync"]("/x","y")'"#, .node)
        expectLimited(#"node -e 'const {writeFileSync: w}=require("fs"); w("/x","y")'"#, .node)
        expectLimited(#"node -e 'const fs=require("fs"); fs.openSync(p, fs.constants.O_WRONLY|fs.constants.O_CREAT)'"#, .node)
        expectLimited(#"node -e 'require("fs").writeFileSync(p,"y")'"#, .node)
    }

    @Test func nodeFileReadsStayAllowed() {
        expectNotWrapper(#"node -e 'console.log(require("fs").readFileSync("f","utf8"))'"#)
        expectNotWrapper(#"node -e 'console.log(1)'"#)
    }

    @Test func rubyFileWritesLimit() {
        expectLimited(#"ruby -e 'File.write("/x","y")'"#, .ruby)
        expectComplete(#"ruby -e 'File.open("/x","w")'"#, inner: "tee -- /x", layers: [.ruby])
        expectComplete(#"ruby -e 'File.open("/x", "a") { |f| f.puts 1 }'"#, inner: "tee -- /x", layers: [.ruby])
        expectComplete(#"ruby -e 'File.open("/x", mode: "w")'"#, inner: "tee -- /x", layers: [.ruby])
        expectComplete(#"ruby -e 'File.new("/x", "w")'"#, inner: "tee -- /x", layers: [.ruby])
        expectComplete(#"ruby -e 'open("/x", "w")'"#, inner: "tee -- /x", layers: [.ruby])
        expectComplete("ruby -e \"File.open '/tmp/x', 'w' do |f| f.puts 1 end\"", inner: "tee -- /tmp/x", layers: [.ruby])
        expectComplete("ruby -e \"open '/tmp/x', 'w' do |f| f.puts 1 end\"", inner: "tee -- /tmp/x", layers: [.ruby])
        expectLimited(#"ruby -e 'File.open(p, "w")'"#, .ruby)
        expectLimited(#"ruby -e 'File.open("/x", File::WRONLY)'"#, .ruby)
    }

    @Test func rubyFileReadsStayAllowed() {
        expectNotWrapper(#"ruby -e 'puts File.read("f")'"#)
        expectNotWrapper(#"ruby -e 'File.open("f") { |f| puts f.read }'"#)
        expectNotWrapper(#"ruby -e 'File.open("f", "r") { |f| puts f.read }'"#)
        expectNotWrapper(#"ruby -e 'File.open("f", File::RDONLY) { |f| puts f.read }'"#)
    }

    // MARK: round-3 review of #491

    @Test func proxyQuotesOperandsThatAreShellSyntax() {
        expectComplete("perl -pi -e 1 ';' ~/.bashrc", inner: "tee -- ';' ~/.bashrc", layers: [.perl])
        expectComplete("perl -pi -e 1 '|' ~/.bashrc", inner: "tee -- '|' ~/.bashrc", layers: [.perl])
        expectComplete("perl -pi -e 1 '&&' ~/.bashrc", inner: "tee -- '&&' ~/.bashrc", layers: [.perl])
    }

    @Test func perlCapitalCTakesNoSeparateValue() {
        expectComplete("perl -C -pi -e 's/a/b/' ~/.bashrc", inner: "tee -- ~/.bashrc", layers: [.perl])
    }

    @Test func sedScriptFromUnreadableSourceLimits() {
        expectLimited("sed -f - f", .sed)
        expectLimited("sed -f /dev/stdin f", .sed)
        expectLimited("sed -f <(echo 'e id') f", .sed)
        expectLimited("sed --file=/proc/self/fd/0 f", .sed)
    }

    @Test func sedBracketDelimitersAndUnparseableScripts() {
        expectComplete("sed -n '/[/]/w /tmp/evil' f", inner: "tee -- /tmp/evil", layers: [.sed])
        expectComplete("sed 's/[/]/x/w /tmp/evil' f", inner: "tee -- /tmp/evil", layers: [.sed])
        expectComplete("sed 's/[^/]*/x/w /tmp/evil' f", inner: "tee -- /tmp/evil", layers: [.sed])
        expectLimited("sed -n 'p;k;w /tmp/evil' f", .sed)
        expectNotWrapper("sed -n '/^#/p' f")
        expectNotWrapper("sed 's/[/]/x/' f")
        #expect(sedScriptEffects("p;k").unparseable)
        #expect(sedScriptEffects("s/a/b/;/x").unparseable)
        #expect(sedScriptEffects("s/a/b/;p").unparseable == false)
    }

    @Test func sedAbbreviatedExpressionOption() {
        expectComplete("gsed --e='w /tmp/evil' f", inner: "tee -- /tmp/evil", layers: [.sed])
    }

    @Test func awkInPlaceWritesItsOperands() {
        expectComplete("gawk -i inplace '{print}' ~/.bashrc", inner: "tee -- ~/.bashrc", layers: [.awk])
        expectComplete("awk -i inplace -v a=1 '{print}' f g", inner: "tee -- f g", layers: [.awk])
        expectNotWrapper("gawk '{print}' ~/.bashrc")
    }

    @Test func perlOpenForWriteAndInPlaceVariableLimit() {
        expectLimited(#"perl -e 'open(F, ">", "/tmp/x")'"#, .perl)
        expectLimited(#"perl -e 'open F, ">/tmp/x"'"#, .perl)
        expectLimited(#"perl -e 'open(F, ">>/tmp/x")'"#, .perl)
        expectLimited(#"perl -e 'open(F, "+<", "/tmp/x")'"#, .perl)
        expectLimited(#"perl -pe 'BEGIN{$^I=""}' ~/.bashrc"#, .perl)
        expectNotWrapper(#"perl -e 'open(F, "<", "f"); print <F>'"#)
    }

    @Test func literalInRepoWritesProxyToLocationCheck() {
        expectComplete(#"python3 -c "import json; json.dump({}, open('out.json','w'))""#, inner: "tee -- out.json", layers: [.python])
        expectComplete(#"node -e "require('fs').writeFileSync('out.txt','y')""#, inner: "tee -- out.txt", layers: [.node])
        expectNotWrapper(#"python3 -c "import zipfile; zipfile.ZipFile('a.zip').open('member.txt')""#)
    }

    // MARK: round-4 review of #491 (literal-path proxy must fail closed)

    @Test func chdirMakesRelativeLiteralPathsUnresolvable() {
        expectLimited(#"python3 -c "import os; os.chdir('/'); open('tmp/pwn','w').write('x')""#, .python)
        expectLimited(#"python3 -c "import contextlib; contextlib.chdir('/'); open('tmp/pwn','w').write('x')""#, .python)
        expectLimited(#"node -e "process.chdir('/'); require('fs').writeFileSync('tmp/pwn','x')""#, .node)
        expectLimited(#"ruby -e "Dir.chdir('/'); File.open('tmp/pwn','w'){|f| f<<'x'}""#, .ruby)
    }

    @Test func rubyInterpolatedPathIsNotALiteral() {
        expectLimited(##"ruby -e '@p="/tmp/x"; File.open("#@p","w"){|f| f<<"x"}'"##, .ruby)
        expectLimited(##"ruby -e'@p="/tmp/x"; File.open("#@p","w"){|f| f<<"x"}'"##, .ruby)
    }

    @Test func rubyParenlessCallsFailClosed() {
        expectComplete(
            #"ruby -e 'File.open "/Users/me/.bashrc", "a#{}" do |f| f.puts 1 end'"#,
            inner: "tee -- /Users/me/.bashrc", layers: [.ruby]
        )
        expectLimited(
            "ruby -e \"File.open '/Users/me/.bashrc', ({}.nil? ? 'a':'a') do |f| f.puts 1 end\"", .ruby
        )
    }

    @Test func nodeFsUseBeyondDirectLiteralWritersLimits() {
        expectLimited(#"node -e 'require("fs").cpSync("package.json","/Users/me/.bashrc")'"#, .node)
        expectLimited(#"node -e 'require("fs").truncateSync(p,0)'"#, .node)
        expectLimited(#"node -e 'require("fs").symlinkSync("a","/x")'"#, .node)
        expectLimited(#"node -e 'require("fs").linkSync("a","/x")'"#, .node)
        expectLimited(#"node -e 'const f=require("fs"); f.truncateSync(p,0)'"#, .node)
        expectLimited(#"node -e 'const {cpSync}=require("fs"); cpSync(a,"/x")'"#, .node)
        expectLimited(#"node -e 'require("fs").writeFileSync.call(null,"/x","y")'"#, .node)
        expectLimited(#"node -e 'require("fs").writeFileSync.apply(null,["/x","y"])'"#, .node)
        expectLimited(#"node -e 'const w=require("fs").writeFileSync; w("/x","y")'"#, .node)
        expectLimited(#"node -e 'fs.writeSync(fs.openSync("/x",577),"y")'"#, .node)
        expectLimited(#"node -e 'require("fs")["write"+"FileSync"]("/x","y")'"#, .node)
        expectLimited(#"node -e 'fs.cpSync("a","/x")'"#, .node)
        expectLimited(#"node -e 'require("fs").openSync("/x", 577)'"#, .node)
        expectNotWrapper(#"node -e 'console.log(require("fs").readFileSync("f","utf8"))'"#)
        expectNotWrapper(#"node -e 'const fs=require("fs"); console.log(fs.existsSync("f"))'"#)
    }

    @Test func pythonPathModeVariableAndMultipleShellCalls() {
        expectLimited(#"python3 -c "import pathlib; m='w'; pathlib.Path('/tmp/x').open(m)""#, .python)
        expectLimited(#"python3 -c "import os; os.system('true'); os.system('rm -rf ~')""#, .python)
    }

    @Test func perlDigitClustersAndExtraWriteMarkers() {
        expectLimited(#"perl -0777pe 'open(F,">","/tmp/x")' f"#, .perl)
        expectLimited(#"perl -e 'sysopen(F,"/tmp/x",1)'"#, .perl)
        expectLimited(#"perl -e 'use IO::File; IO::File->new("/tmp/x","w")'"#, .perl)
        expectLimited(#"perl -e 'use File::Copy; copy("a","/tmp/x")'"#, .perl)
        expectLimited(#"perl -e 'open(F, $mode, "/tmp/x")'"#, .perl)
    }

    @Test func awkInPlaceVariants() {
        expectComplete("gawk -i inplace.awk '{print}' ~/.bashrc", inner: "tee -- ~/.bashrc", layers: [.awk])
        expectComplete("gawk --inc=inplace '{print}' ~/.bashrc", inner: "tee -- ~/.bashrc", layers: [.awk])
        expectComplete("gawk --include inplace '{print}' ~/.bashrc", inner: "tee -- ~/.bashrc", layers: [.awk])
        expectComplete("gawk -E prog.awk -i inplace ~/.bashrc", inner: "tee -- ~/.bashrc", layers: [.awk])
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
