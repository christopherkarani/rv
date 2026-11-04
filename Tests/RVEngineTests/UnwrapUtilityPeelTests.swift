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
