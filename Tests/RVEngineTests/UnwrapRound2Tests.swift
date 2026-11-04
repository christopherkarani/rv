import Testing
import RVDomain
@testable import RVEngine

@Suite("Unwrap round 2: segment heads, peels, interpreters")
struct UnwrapRound2Tests {
    // MARK: segment heads

    @Test func timeAndCoprocAreStrippedFromSegments() {
        #expect(splitSegments("time rm -r ~") == ["rm -r ~"])
        #expect(splitSegments("time -p rm -r ~") == ["rm -r ~"])
        #expect(splitSegments("coproc rm -r ~") == ["rm -r ~"])
        #expect(splitSegments("echo time") == ["echo time"])
    }

    @Test func caseArmsExposeTheirCommands() {
        #expect(splitSegments("case x in x) rm -r ~;; esac").contains("rm -r ~"))
        #expect(splitSegments("case x in (x) rm -r ~;; esac").contains("rm -r ~"))
        #expect(splitSegments("case $a in\nx) rm -r ~ ;;\nesac").contains("rm -r ~"))
        #expect(splitSegments("case x in x) rm -r ~;& y) :;; esac").contains("rm -r ~"))
        #expect(splitSegments("case x in a|b) rm -r ~;; esac").contains("rm -r ~"))
    }

    @Test func functionBodiesExposeTheirCommands() {
        #expect(splitSegments("x() { rm -r ~; }; x").contains("rm -r ~"))
        #expect(splitSegments("function x { rm -r ~; }; x").contains("rm -r ~"))
        #expect(splitSegments("x () { rm -r ~; }").contains("rm -r ~"))
    }

    @Test func reservedWordsGluedToParensAreSplit() {
        #expect(splitSegments("if(rm -r ~); then :; fi").contains("rm -r ~"))
        #expect(splitSegments("if :; then(rm -r ~); fi").contains("rm -r ~"))
        #expect(splitSegments("if :; then :; else(rm -r ~); fi").contains("rm -r ~"))
        #expect(splitSegments("for x in 1; do(rm -r ~); done").contains("rm -r ~"))
        #expect(splitSegments("while(rm -r ~); do :; done").contains("rm -r ~"))
        #expect(splitSegments("if !(rm -r ~); then :; fi").contains("rm -r ~"))
    }

    @Test func escapedAndQuotedSeparatorsDoNotSplit() {
        #expect(splitSegments("find . -exec echo {} \\; -print") == ["find . -exec echo {} \\; -print"])
        #expect(splitSegments("echo a\\;b") == ["echo a\\;b"])
        #expect(splitSegments("echo ';' x") == ["echo ';' x"])
    }

    // MARK: peels

    @Test func nohupAndExecDropLeadingDoubleDash() {
        expectComplete("nohup -- rm -r ~", inner: "rm -r ~", layers: [.nohup])
        expectComplete("nohup -- sudo rm -r ~", inner: "rm -r ~", layers: [.nohup, .sudo])
    }

    @Test func clusteredFlagsEndingInValueFlagConsumeNextWord() {
        expectComplete("doas -nu root rm -r ~", inner: "rm -r ~", layers: [.doas])
        expectComplete("sudo -nu root rm -r ~", inner: "rm -r ~", layers: [.sudo])
        expectComplete("sudo -Eu root rm -r ~", inner: "rm -r ~", layers: [.sudo])
        expectComplete("sudo -n rm -r ~", inner: "rm -r ~", layers: [.sudo])
    }

    @Test func xargsGnuReplaceAndLongOptions() {
        expectLimited(#"xargs -i sh -c "rm -r {}""#, .xargs)
        expectLimited(#"xargs -iX sh -c "rm -r X""#, .xargs)
        expectLimited("xargs --arg-file l rm -r", .xargs)
        expectLimited("xargs --arg-file=l rm -r", .xargs)
        expectLimited("xargs --delimiter x rm -r", .xargs)
        expectLimited("xargs --eof=x rm -r", .xargs)
        expectLimited("xargs --max-args 1 rm -r", .xargs)
        expectLimited("xargs --frobnicate grep x", .xargs)
        expectComplete("xargs --arg-file l grep x", inner: "grep x", layers: [.xargs])
        expectComplete("xargs --max-procs 4 --null grep x", inner: "grep x", layers: [.xargs])
        expectComplete("xargs -0 sed -n 1p", inner: "sed -n 1p", layers: [.xargs])
        expectLimited("xargs sed -i s/a/b/", .xargs)
        expectLimited("xargs sed -ni p", .xargs)
        expectLimited("xargs sed --in-place s/a/b/", .xargs)
    }

    // MARK: interpreters

    @Test func pythonEverydayProgramsPass() {
        expectNotWrapper(#"python3 -c 'import os; print(os.getcwd())'"#)
        expectNotWrapper(#"python3 -c 'print(eval("1+1"))'"#)
        expectNotWrapper(#"python3 -c 'import re; re.compile("a")'"#)
        expectNotWrapper(#"python3 -c 'import os.path; print(os.path.join("a", "b"))'"#)
    }

    @Test func pythonDangerousCallablesStillLimit() {
        expectLimited(#"python3 -c 'import os; os.system(x)'"#, .python)
        expectLimited(#"python3 -c 'import os; os.execvp(x, y)'"#, .python)
        expectLimited(#"python3 -c 'import os; os.kill(1, 9)'"#, .python)
        expectLimited(#"python3 -c 'import os as o; o.system(x)'"#, .python)
        expectLimited(#"python3 -c 'from os import system; system(x)'"#, .python)
        expectLimited(#"python3 -c 'from os import *; system(x)'"#, .python)
        expectLimited(#"python3 -c 'from os import path'"#, .python)
        expectLimited(#"python3 -c 'import re, os as o; o.system(x)'"#, .python)
        expectLimited(#"python3 -c 'import os; getattr(os, "sys" + "tem")(x)'"#, .python)
        expectLimited(#"python3 -c 'import shutil; shutil.move(a, b)'"#, .python)
        expectLimited(#"python3 -c 'import subprocess'"#, .python)
        expectLimited(#"python3 -c 'exec(x)'"#, .python)
        expectLimited(#"python3 -c 'print(eval(input()))'"#, .python)
        expectLimited(#"python3 -c 'compile(x, "f", "exec")'"#, .python)
        expectLimited(#"python3 -c '__import__("os")'"#, .python)
    }

    @Test func perlBlockEvalPassesStringEvalLimits() {
        expectNotWrapper(#"perl -e 'print eval { 1 }'"#)
        expectLimited(#"perl -e 'eval "1"'"#, .perl)
        expectLimited(#"perl -e 'eval { system("id") }'"#, .perl)
    }

    @Test func rubyEverydayProgramsPass() {
        expectNotWrapper(#"ruby -e 'puts Process.pid'"#)
        expectNotWrapper(#"ruby -e 'puts IO.readlines("f").size'"#)
    }

    @Test func rubyDangerousCallsStillLimit() {
        expectLimited(#"ruby -e 'open("|rm -r ~")'"#, .ruby)
        expectLimited(#"ruby -e 'Process.spawn(x)'"#, .ruby)
        expectLimited(#"ruby -e 'IO.popen(x)'"#, .ruby)
        expectLimited(#"ruby -e 'send(:system, x)'"#, .ruby)
        expectLimited(#"ruby -e 'File.rename(a, b)'"#, .ruby)
        expectLimited(#"ruby -e 'Dir.rmdir(a)'"#, .ruby)
        expectLimited(#"ruby -e 'require "open3"; Open3.capture2(x)'"#, .ruby)
        expectLimited(#"ruby -e 'eval(x)'"#, .ruby)
        expectLimited(#"ruby -e 'puts %x(id)'"#, .ruby)
    }

    @Test func luaAndPhpProgramsLimitUnlessProvablyPlain() {
        expectLimited(#"lua -e 'local o=os; o.execute("x")'"#, .lua)
        expectLimited(#"lua -e 'require("os")'"#, .lua)
        expectLimited(#"lua -e '_G["o".."s"].execute("x")'"#, .lua)
        expectLimited(#"php -r '$f="sys"."tem"; $f("x");'"#, .php)
        expectLimited(#"php -r '("sys"."tem")("x");'"#, .php)
        expectLimited(#"php -r 'array_map("sys"."tem", ["x"]);'"#, .php)
        expectNotWrapper(#"lua -e 'print(1 + 1)'"#)
        expectNotWrapper(#"php -r 'echo 1 + 1;'"#)
    }

    @Test func awkPipesStdinProgramsAndMultipleSources() {
        expectLimited(#"awk 'BEGIN{c="sh"; print "rm -r ~" | c}'"#, .awk)
        expectLimited(#"awk 'BEGIN{"id" | getline x}'"#, .awk)
        expectLimited("awk -f /dev/stdin f", .awk)
        expectLimited("awk -f - f", .awk)
        expectLimited(#"gawk -e 'BEGIN{x=1}' -e 'BEGIN{system("id")}'"#, .awk)
        expectNotWrapper("awk -f script.awk f")
        expectNotWrapper(#"awk '$1 == "a" || $2 == "b" {print}' f"#)
        expectNotWrapper(#"awk '/a|b/ {print}' f"#)
        expectNotWrapper(#"awk '{print ($1 > 5)}' f"#)
        expectNotWrapper(#"awk '{if ($1 > 5) print "big"}' f"#)
        expectLimited(#"awk '{print $1 > 5}' f"#, .awk)
        expectLimited(#"awk '{print $1 >> "out"}' f"#, .awk)
    }

    // MARK: git

    @Test func gitCheckoutForceWithSeveralPathspecsIsADiscard() {
        let single = analyzeGit(ShellCommand(rawValue: "git checkout --force ."))
        #expect(single.gitAction == .switchBranch(name: ".", force: true))
        let two = analyzeGit(ShellCommand(rawValue: "git checkout --force . ."))
        #expect(two.gitAction == .discardWorktree(pathspecs: ["."], source: "."))
        let short = analyzeGit(ShellCommand(rawValue: "git checkout -f HEAD a b"))
        #expect(short.gitAction == .discardWorktree(pathspecs: ["a", "b"], source: "HEAD"))
    }

    /// Git itself rejects these as ambiguous prefixes, so the parser leaves
    /// them unparsed rather than guessing.
    @Test func ambiguousGitLongOptionPrefixesStayUnparsed() {
        #expect(analyzeGit(ShellCommand(rawValue: "git switch --forc main")).gitAction == nil)
        #expect(analyzeGit(ShellCommand(rawValue: "git push --forc")).gitAction == .pushUnparsed(args: ["--forc"]))
    }
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
