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
        "python3 -c 'import os; os.system(\"pkill -f rvd\")'",
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
        "launchctl kickstart -k gui/501/dev.rv.evaluate",
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

    @Test("commands that stop or kill rvd are flagged", arguments: stopping)
    func stoppingFlagged(command: String) {
        #expect(RVDStopGuard.stopsRVD(command), "\(command)")
    }

    @Test("everyday process and service commands are not", arguments: benign)
    func benignPass(command: String) {
        #expect(RVDStopGuard.stopsRVD(command) == false, "\(command)")
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
