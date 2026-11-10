import Foundation
import Testing
import RVDomain
@testable import RVEngine

/// An agent must never stop rvd: with rvd unreachable, an observe host
/// allows every later call unchecked. Observe hosts floor these
/// (`ObserveFloor`); in enforce a stopped rvd fails closed anyway.
@Suite("rvd lifecycle guard")
struct RVDLifecycleGuardTests {
    static let stopping: [String] = [
        // launchd
        "launchctl bootout gui/501/dev.rv.evaluate",
        "launchctl bootout gui/$(id -u)/dev.rv.evaluate",
        "launchctl bootout gui/$UID",
        "launchctl bootout gui/501",
        "launchctl bootout gui/501 ~/Library/LaunchAgents/dev.rv.evaluate.plist",
        "launchctl unload ~/Library/LaunchAgents/dev.rv.evaluate.plist",
        "launchctl unload -w ~/Library/LaunchAgents/dev.rv.evaluate.plist",
        "launchctl unload ~/Library/LaunchAgents",
        "launchctl unload ~/Library/LaunchAgents/*.plist",
        "launchctl remove dev.rv.evaluate",
        // a plist is opaque: launchd stops whatever Label it names
        "launchctl unload /tmp/x.plist",
        "launchctl stop dev.rv.evaluate",
        "launchctl kickstart -k gui/501/dev.rv.evaluate",
        "launchctl kill SIGKILL gui/501/dev.rv.evaluate",
        "launchctl kill 9 gui/501/dev.rv.evaluate",
        "launchctl disable gui/501/dev.rv.evaluate",
        "launchctl bootout $TARGET",
        "launchctl $VERB gui/501/dev.rv.evaluate",
        "launchctl `echo bootout` gui/501/dev.rv.evaluate",
        "LAUNCHCTL BOOTOUT gui/501/DEV.RV.EVALUATE",
        "/bin/launchctl bootout gui/501/dev.rv.evaluate",
        "launchctl asuser 501 launchctl bootout gui/501/dev.rv.evaluate",
        // systemd
        "systemctl --user stop dev.rv.evaluate.service",
        "systemctl --user stop dev.rv.evaluate",
        "systemctl --user disable --now dev.rv.evaluate.service",
        "systemctl --user mask dev.rv.evaluate.service",
        "systemctl --user kill dev.rv.evaluate.service",
        "systemctl --user kill -s KILL dev.rv.evaluate.service",
        "systemctl --user restart dev.rv.evaluate.service",
        "systemctl --user stop 'dev.rv.*'",
        "systemctl --user stop $UNIT",
        "systemctl --user isolate rescue.target",
        "systemctl --user exit",
        "systemctl --user set-environment RV_GUARD_MODE=off",
        "systemctl --user $VERB dev.rv.evaluate.service",
        // signals by name
        "pkill rvd",
        "pkill -9 rvd",
        "pkill -f rvd",
        "pkill -f .local/bin/rvd",
        "pkill -x rvd",
        "pkill rv",
        "pkill 'r.d'",
        "pkill .",
        "pkill $NAME",
        "pkill -v node",
        "pkill -u $USER",
        "pkill -U 501",
        "killall rvd",
        "killall -9 rvd",
        "killall -KILL rvd",
        "killall -u chris",
        "killall $NAME",
        "killall rv*",
        "kill $(pgrep rvd)",
        "kill -9 $(pgrep -f 'r.d')",
        "kill `pidof rvd`",
        "kill -9 -1",
        "kill -- -1",
        "pgrep rvd | xargs kill",
        "kill $(launchctl list | grep dev.rv | cut -f1)",
        "kill $(lsof -t ~/.config/rv/evaluate.sock)",
        // launching a second rvd unlinks the live socket
        "rvd",
        "~/.local/bin/rvd &",
        // wrappers, prefixes, env assignments, chains
        "sudo launchctl bootout gui/501/dev.rv.evaluate",
        "env FOO=1 launchctl bootout gui/501/dev.rv.evaluate",
        "FOO=1 pkill rvd",
        "nohup pkill rvd",
        "timeout 5 systemctl --user stop dev.rv.evaluate.service",
        "sh -c 'launchctl bootout gui/501/dev.rv.evaluate'",
        "bash -lc \"pkill -f rvd\"",
        "true; launchctl bootout gui/501/dev.rv.evaluate",
        "ls && killall rvd",
        "echo hi | xargs launchctl bootout gui/501/dev.rv.evaluate",
        "find . -maxdepth 0 -exec launchctl bootout gui/501/dev.rv.evaluate \\;",
        "$LAUNCHER bootout gui/501/dev.rv.evaluate",
    ]

    static let benign: [String] = [
        "kill %1",
        "kill -9 %1",
        "kill 1234",
        "kill -TERM 1234",
        "kill $!",
        "kill -l",
        "kill $(lsof -ti:3000)",
        "pkill node",
        "pkill -f 'node server.js'",
        "pkill -9 -f vite",
        "killall node",
        "killall -9 Simulator",
        "pgrep rvd",
        "pgrep -fl rvd",
        "launchctl list",
        "launchctl list | grep dev.rv",
        "launchctl print gui/501/dev.rv.evaluate",
        "launchctl bootstrap gui/501 ~/Library/LaunchAgents/dev.rv.evaluate.plist",
        "launchctl bootout gui/501/com.example.agent",
        "systemctl --user status rvd",
        "systemctl --user status dev.rv.evaluate.service",
        "systemctl --user restart myapp.service",
        "systemctl --user stop myapp",
        "systemctl --user daemon-reload",
        "systemctl --user list-units",
        "journalctl --user -u dev.rv.evaluate.service",
        "rm build/rvd.o",
        "grep -rn pkill Sources",
        "echo kill the server",
        "git log --grep launchctl",
        "swift build --product rvd",
        ".build/debug/rv-cli doctor",
    ]

    // Round-2 coverage: xargs/stdin-fed stop programs, PID lookups that hide
    // the name, echo/printf piped to a shell or scheduler, and D-Bus stops.
    static let stoppingR2: [String] = [
        "launchctl kickstart -k gui/501/dev.rv.evaluate",
        "pgrep rvd | xargs -I{} kill {}",
        "pgrep rvd | xargs -I % kill %",
        "echo rvd | xargs pkill",
        "echo rvd | xargs killall -9",
        "xargs pkill < names.txt",
        "echo gui/501/dev.rv.evaluate | xargs -n1 launchctl bootout",
        "ps ax | grep '[r]vd' | awk '{print $1}' | xargs kill",
        "kill $(ps ax | awk '/rv[d]/{print $1}')",
        "ps ax | grep 'r''vd' | awk '{print $1}' | xargs kill",
        "kill $(launchctl list | awk '/dev.r.\\./{print $1}')",
        "pkill -f 'bob.*rvd'",
        "echo \"launchctl bootout gui/501/dev.rv.evaluate\" | sh",
        "printf 'pkill rvd' | bash",
        "echo \"pkill rvd\" | at now",
        "crontab -l | { cat; echo '* * * * * pkill rvd'; } | crontab -",
        "busctl --user stop dev.rv.evaluate",
        "dbus-send --session /dev/rv dev.rv.Stop",
    ]

    // Round-2 false positives that must stay allowed: a quoted pattern is one
    // regex, a non-name selection narrows, a quoted message is not a command.
    static let benignR2: [String] = [
        "pkill -f 'rails s'",
        "pkill -u $USER Slack",
        "pkill -P $$",
        "git commit -m 'fix: pkill rvd bug'",
        "brew install rv",
        "brew services stop rv",
        "swift build --product rv",
        "swift run rvd",
        "git log --grep='rvd'",
    ]

    @Test("commands that stop or kill rvd are flagged", arguments: stopping + stoppingR2)
    func stoppingFlagged(command: String) {
        #expect(RVDStopGuard.stopsRVD(command), "\(command)")
    }

    @Test("everyday process and service commands are not", arguments: benign + benignR2)
    func benignPass(command: String) {
        #expect(RVDStopGuard.stopsRVD(command) == false, "\(command)")
    }

    // Residual (documented, not attempted): an agent-supplied pattern cannot
    // hang the gate. A nested-quantifier/backreference pattern or an
    // oversized word list fails closed within a hard time bound.
    @Test("agent-supplied patterns and word lists evaluate in bounded time")
    func boundedTime() {
        let adversarial = [
            "pkill -f '" + String(repeating: "(.|.)", count: 40) + "+X'",
            "pkill -f '" + String(repeating: "(a+)", count: 30) + "+b'",
            "pkill -f '" + String(repeating: "a", count: 5000) + "'",
            "launchctl bootout " + Array(repeating: "x", count: 4000).joined(separator: " "),
            "kill $(ps ax | grep '" + String(repeating: "(x+)", count: 40) + "+y')",
        ]
        let start = Date()
        for command in adversarial { _ = RVDStopGuard.stopsRVD(command) }
        #expect(Date().timeIntervalSince(start) < 2.0)
    }

    @Test("rv setup --observe sheds oversight; plain setup does not", arguments: [
        ("rv setup --observe", true),
        ("rv setup --force --observe", true),
        ("rv setup $FLAGS", true),
        ("rv-cli setup --observe", true),
        ("sh -c 'rv setup --observe'", true),
        ("rv setup", false),
        ("rv setup --force", false),
        ("rv setup --json", false),
    ])
    func setupObserve(command: String, flagged: Bool) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)) == flagged, "\(command)")
    }
}
