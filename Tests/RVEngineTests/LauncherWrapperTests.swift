import Testing
import RVDomain
@testable import RVEngine

/// Transparent exec wrappers (`setsid`, `stdbuf`, `ionice`, `chrt`, `taskset`,
/// `flock`, ...) run their command operand, so the shared launcher resolver
/// must see through them, honouring each one's option grammar. An option it
/// cannot model fails closed: every later operand may be the real command.
@Suite("launcher resolver: transparent exec wrappers")
struct LauncherWrapperTests {
    static let weakening: [String] = [
        "setsid rv uninstall",
        "setsid -w rv uninstall",
        "setsid -cfw rv uninstall",
        "setsid --fork --wait rv uninstall",
        "setsid -- rv uninstall",
        "stdbuf -oL rv uninstall",
        "stdbuf -o L rv uninstall",
        "stdbuf -i0 -o L -e L rv uninstall",
        "stdbuf --output=L rv uninstall",
        "stdbuf --output L rv uninstall",
        "stdbuf --out L rv uninstall",
        "ionice rv uninstall",
        "ionice -c 3 -n 7 rv uninstall",
        "ionice -c3 -n7 -t rv uninstall",
        "ionice --class idle rv uninstall",
        "ionice --class=idle rv uninstall",
        "chrt -f 10 rv uninstall",
        "chrt --rr 5 rv uninstall",
        "chrt -b 0 rv uninstall",
        "chrt -i rv uninstall",
        "chrt -d -T 1000 -P 2000 -D 2000 0 rv uninstall",
        "chrt --sched-runtime 1000 0 rv uninstall",
        "taskset 0x3 rv uninstall",
        "taskset -c 0-3 rv uninstall",
        "taskset --cpu-list 0,2 rv uninstall",
        "taskset -a ff rv uninstall",
        "flock /tmp/l rv uninstall",
        "flock -w 5 /tmp/l rv uninstall",
        "flock -xn -E 9 /tmp/l rv uninstall",
        "flock --timeout=5 /tmp/l rv uninstall",
        "flock /tmp/l -c 'rv uninstall'",
        "flock -s /tmp/l --command 'rv packs disable core.git'",
        "unbuffer rv uninstall",
        "unbuffer -p rv uninstall",
        "caffeinate rv uninstall",
        "caffeinate -dims rv uninstall",
        "caffeinate -t 60 rv uninstall",
        "nocache rv uninstall",
        "nocache -n 2 rv uninstall",
        "numactl --interleave=all rv uninstall",
        "numactl -N 0 -m 0 rv uninstall",
        "numactl --cpunodebind 0 --localalloc rv uninstall",
        "prlimit --nofile=1024 rv uninstall",
        "prlimit -n1024 --as rv uninstall",
        "chpst -u nobody -n 5 rv uninstall",
        "chpst -v -P rv uninstall",
        "firejail --quiet rv uninstall",
        "firejail --private=/tmp/x rv uninstall",
        // Nested wrappers and the existing launchers compose.
        "setsid stdbuf -oL nice -n 5 rv uninstall",
        "sudo -u root ionice -c 3 rv uninstall",
        "nohup setsid -f rv uninstall",
        "setsid bash -c 'rv uninstall'",
        "ionice -c 3 env -S 'rv uninstall'",
        "/usr/bin/setsid rv uninstall",
        "SETSID rv uninstall",
        "$'setsid' rv uninstall",
        "ls && stdbuf -oL rv packs disable core.git",
        // Unknown or unmodelled options fail closed: any later word may be the command.
        "setsid --bogus x rv uninstall",
        "stdbuf -Z q rv uninstall",
        "ionice --frob 9 rv uninstall",
        "chrt -Q 3 rv uninstall",
        "taskset -z 1 rv uninstall",
        "flock -k 3 /tmp/l rv uninstall",
        "flock --what 3 /tmp/l -c 'rv uninstall'",
        "caffeinate -q 1 rv uninstall",
        "ionice --p 1 rv uninstall",
        "chrt $PRIO rv uninstall",
        "stdbuf $OPT rv uninstall",
    ]

    static let harmless: [String] = [
        "setsid ls",
        "stdbuf -oL tail -f log",
        "ionice -c 3 make",
        "chrt -f 10 make -j8",
        "taskset -c 0-3 swift build",
        "flock /tmp/l make",
        "flock /tmp/l -c 'make test'",
        "unbuffer -p cat",
        "caffeinate -i swift test",
        "setsid rv doctor",
        "stdbuf -oL rv packs list",
        "ionice --bogus 3 make",
        "taskset rv",
        "flock rv uninstall",
    ]

    @Test("rv administration behind a transparent wrapper hits the self-protection floor", arguments: weakening)
    func wrappedWeakeningIsFlagged(_ raw: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: raw)), "\(raw)")
    }

    @Test("ordinary commands behind a transparent wrapper are not flagged", arguments: harmless)
    func wrappedHarmlessIsNotFlagged(_ raw: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: raw)) == false, "\(raw)")
    }

    @Test("the resolver yields the wrapped command with each wrapper's option grammar")
    func resolvesWrappedCommand() {
        #expect(launchedCommands("setsid -w rv uninstall") == [["rv", "uninstall"]])
        #expect(launchedCommands("stdbuf -o L cat x") == [["cat", "x"]])
        #expect(launchedCommands("stdbuf -oL cat x") == [["cat", "x"]])
        #expect(launchedCommands("ionice -c 3 -n 7 cat x") == [["cat", "x"]])
        #expect(launchedCommands("chrt -f 10 cat x") == [["cat", "x"]])
        #expect(launchedCommands("chrt -i cat x") == [["cat", "x"]])
        #expect(launchedCommands("taskset 0x3 cat x") == [["cat", "x"]])
        #expect(launchedCommands("taskset -c 0-3 cat x") == [["cat", "x"]])
        #expect(launchedCommands("flock -w 5 /tmp/l cat x") == [["cat", "x"]])
        #expect(launchedCommands("flock /tmp/l -c 'cat x'") == [["cat", "x"]])
        #expect(launchedCommands("prlimit --nofile=1024 cat x") == [["cat", "x"]])
        #expect(launchedCommands("setsid stdbuf -oL python3 -c 'print(1)'") == [["python3", "-c", "print(1)"]])
        #expect(launchedCommands("X=1 setsid cat x") == [["cat", "x"]])
    }

    @Test("an unmodelled wrapper option leaves the wrapper as the command, never a guessed head")
    func unknownOptionKeepsWrapper() {
        #expect(launchedCommands("stdbuf -Z q cat x") == [["stdbuf", "-Z", "q", "cat", "x"]])
        #expect(launchedCommands("ionice --p 1 cat x") == [["ionice", "--p", "1", "cat", "x"]])
    }

    @Test("a brace expansion naming a wrapper is judged unmodelled")
    func braceExpansionNamingWrapper() {
        #expect(hasSensitiveBraceExpansion("{setsid,rv} uninstall"))
    }
}
