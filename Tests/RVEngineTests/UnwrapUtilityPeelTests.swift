import Testing
import RVDomain
@testable import RVEngine

@Suite("Unwrap utility peels")
struct UnwrapUtilityPeelTests {
    @Test func findExecSubstitutesStartPaths() {
        expectComplete("find ~ -exec rm -r {} +", inner: "rm -r ~", layers: [.find])
        expectComplete("find ~ -execdir rm -r {} \\;", inner: "rm -r ~", layers: [.find])
        expectComplete("find ~ -ok rm -r {} \\;", inner: "rm -r ~", layers: [.find])
        expectComplete("find ~ -okdir rm -r {} +", inner: "rm -r ~", layers: [.find])
        expectComplete("find /a /b -exec rm -r {} +", inner: "rm -r /a /b", layers: [.find])
        expectComplete("find . -exec grep foo {} +", inner: "grep foo .", layers: [.find])
        expectComplete("find -L ~ -name x -exec rm {} +", inner: "rm ~", layers: [.find])
    }

    @Test func findExecFailsClosedWhenUnterminatedOrRepeated() {
        expectLimited("find ~ -exec rm -r {}", .find)
        expectLimited("find ~ -exec rm {} \\; -exec rm -r {} \\;", .find)
    }

    @Test func findWithoutExecIsNotWrapper() {
        expectNotWrapper("find . -name '*.swift'")
    }

    @Test func xargsLimitsMutatingPrograms() {
        expectLimited("xargs rm -r", .xargs)
        expectLimited("xargs -0 -n 1 rm", .xargs)
        expectLimited("xargs -I {} rm -r {}", .xargs)
        expectLimited("xargs git reset", .xargs)
        expectLimited("xargs git checkout", .xargs)
        expectLimited("xargs sudo rm -r", .xargs)
        expectLimited("xargs chmod 777", .xargs)
        expectLimited("xargs -I% sh -c 'rm -r %'", .xargs)
    }

    @Test func xargsPeelsReadOnlyPrograms() {
        expectComplete("xargs grep foo", inner: "grep foo", layers: [.xargs])
        expectComplete("xargs wc -l", inner: "wc -l", layers: [.xargs])
        expectComplete("xargs cat", inner: "cat", layers: [.xargs])
        expectComplete("xargs -0 -n 2 -P 4 grep -l x", inner: "grep -l x", layers: [.xargs])
        expectComplete("xargs git log", inner: "git log", layers: [.xargs])
    }

    @Test func nohupAndDoasPeelLikePrefixWrappers() {
        expectComplete("nohup rm -r ~", inner: "rm -r ~", layers: [.nohup])
        expectComplete("doas rm -r ~", inner: "rm -r ~", layers: [.doas])
        expectComplete("doas -u root rm -r ~", inner: "rm -r ~", layers: [.doas])
    }

    @Test func laterChainSegmentsPeel() {
        expectComplete("ls && sudo rm -r ~", inner: "ls ; rm -r ~", layers: [.sudo])
        expectLimited("echo x | xargs rm", .xargs)
        expectNotWrapper("ls && git status")
    }

    @Test func inlineInterpreterSpawnMarkersLimit() {
        expectLimited(#"perl -e 'system("rm -rf ~")'"#, .perl)
        expectLimited(#"perl -le 'print `id`'"#, .perl)
        expectLimited(#"perl -e 'unlink glob("*")'"#, .perl)
        expectLimited(#"awk 'BEGIN{system("rm -rf ~")}'"#, .awk)
        expectLimited(#"gawk '{print $1 | "sh"}' f"#, .awk)
        expectLimited(#"awk '{print > "out"}' f"#, .awk)
        expectLimited(#"php -r 'shell_exec("id");'"#, .php)
        expectLimited(#"lua -e 'io.popen("id")'"#, .lua)
    }

    @Test func inlineInterpreterDataProgramsPass() {
        expectNotWrapper(#"awk '{print $1}' file"#)
        expectNotWrapper(#"awk '/a|b/ {print}' file"#)
        expectNotWrapper(#"awk -F: '$1 > 5 {print $2}' file"#)
        expectNotWrapper(#"perl -ne 'print if /x/' f"#)
        expectNotWrapper(#"php -r 'echo 1;'"#)
        expectNotWrapper(#"lua -e 'print(1)'"#)
    }

    @Test func pythonNodeRubyGenericSpawnReferencesLimit() {
        expectLimited(#"python3 -c 'import os as o; o.system(x)'"#, .python)
        expectLimited(#"python3 -c 'from os import system; system(x)'"#, .python)
        expectLimited(#"python3 -c 'import importlib; importlib.import_module(x)'"#, .python)
        expectLimited(#"python3 -c 'eval(x)'"#, .python)
        expectLimited(#"node -e 'require("child_process").spawn(x)'"#, .node)
        expectLimited(#"node -e 'const m = "child_process"; require(m).execSync(x)'"#, .node)
        expectLimited(#"ruby -e 'Kernel.system(x)'"#, .ruby)
        expectLimited(#"ruby -e 'system x'"#, .ruby)
        expectLimited(#"ruby -e 'IO.popen(x)'"#, .ruby)
    }

    @Test func pythonNodeRubyPlainProgramsPass() {
        expectNotWrapper(#"python3 -c 'print(1)'"#)
        expectNotWrapper(#"node -e 'console.log(1)'"#)
        expectNotWrapper(#"ruby -e 'puts 1'"#)
    }

    @Test func reservedWordsAreStrippedFromSegments() {
        #expect(splitSegments("if :; then rm -r ~; fi").contains("rm -r ~"))
        #expect(splitSegments("while true; do rm -r ~; done").contains("rm -r ~"))
        #expect(splitSegments("! rm -r ~") == ["rm -r ~"])
        #expect(splitSegments("echo then") == ["echo then"])
    }

    @Test func gitLongOptionPrefixesResolveWhenUnique() {
        #expect(resolveGitLongOptions(subcommand: "reset", args: ["--har"]) == ["--hard"])
        #expect(resolveGitLongOptions(subcommand: "reset", args: ["--so", "HEAD"]) == ["--soft", "HEAD"])
        #expect(resolveGitLongOptions(subcommand: "clean", args: ["--forc", "-d"]) == ["--force", "-d"])
        #expect(resolveGitLongOptions(subcommand: "checkout", args: ["--forc", "."]) == ["--force", "."])
        #expect(resolveGitLongOptions(subcommand: "reset", args: ["--hard"]) == ["--hard"])
    }

    @Test func gitLongOptionAmbiguousUnknownAndPastTerminatorAreUntouched() {
        #expect(resolveGitLongOptions(subcommand: "reset", args: ["--re"]) == ["--re"])
        #expect(resolveGitLongOptions(subcommand: "reset", args: ["--zzz"]) == ["--zzz"])
        #expect(resolveGitLongOptions(subcommand: "reset", args: ["--", "--har"]) == ["--", "--har"])
        #expect(resolveGitLongOptions(subcommand: "log", args: ["--on"]) == ["--on"])
    }

    @Test func gitResetAbbreviationParsesAsHardReset() {
        let analysis = analyzeGit(ShellCommand(rawValue: "git reset --har"))
        #expect(analysis.gitAction == .reset(mode: .hard, target: nil))
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

/// Each unmatched `$(` cost a scan to the end of the text, so a payload of
/// thousands of them was quadratic (a 40 KB hook payload pinned rvd's CPU
/// for minutes). Past `maxUnmatchedSubstitutionOpeners` the segment is
/// unscannable and fails closed; a few unmatched openers are unchanged.
@Test func manyUnmatchedSubstitutionOpenersFailClosedQuickly() {
    let few = "echo " + String(repeating: "$(", count: maxUnmatchedSubstitutionOpeners) + "x"
    #expect(splitSegments(few).contains(unscannableSegment) == false)

    let many = "echo " + String(repeating: "$(", count: 20_000) + "x"
    let started = ContinuousClock.now
    let segments = splitSegments(many)
    #expect(segments.contains(unscannableSegment))
    #expect(ContinuousClock.now - started < .seconds(10))

    let process = "cat " + String(repeating: "<(", count: 5_000) + "x"
    #expect(splitSegments(process).contains(unscannableSegment))
}

/// Discarding output to `/dev/null` writes nothing, so it is no redirect
/// target; every other destination, near-miss spellings included, still is.
@Test func devNullOutputIsNotAWriteTarget() {
    #expect(parseRedirectOnly(["ls", "2>/dev/null"]) == nil)
    #expect(parseRedirectOnly(["make", ">", "/dev/null", "2>&1"]) == nil)
    #expect(parseRedirectOnly(["echo", "x", ">", "/dev/nul"])?.paths == ["/dev/nul"])
    #expect(parseRedirectOnly(["echo", "x", ">/dev/null", ">", "out.txt"])?.paths == ["out.txt"])
    #expect(parseRedirectOnly(["ls", ">/dev/sda"])?.paths == ["/dev/sda"])
}

/// `tee` and `dd` writing exactly `/dev/null` write nothing; any other
/// target is still a write (out of repo here: no working directory).
@Test func devNullWriterTargets() {
    #expect(parseTee(["/dev/null"]) == nil)
    #expect(parseTee(["-a", "/dev/null"]) == nil)
    #expect(parseTee(["/dev/null", "out.txt"])?.paths == ["out.txt"])
    #expect(parseTee(["/dev/nul"])?.paths == ["/dev/nul"])
    #expect(parseTee(["/dev/sda"])?.paths == ["/dev/sda"])
    #expect(parseTee(["./dev/null"])?.paths == ["./dev/null"])
    #expect(parseDd(["if=/dev/zero", "of=/dev/null", "count=1"]) == nil)
    #expect(parseDd(["if=x", "of=/dev/null", "of=/tmp/y"])?.paths == ["/tmp/y"])
    #expect(parseDd(["if=/dev/zero", "of=/dev/sda"])?.paths == ["/dev/sda"])
    #expect(parseDd(["if=/dev/zero", "of=/dev//null"])?.paths == ["/dev//null"])
}
