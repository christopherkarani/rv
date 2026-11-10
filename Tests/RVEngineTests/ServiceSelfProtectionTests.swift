import Testing
import RVDomain
@testable import RVEngine

/// rvd takes posture from its launch environment and must stay running:
/// an agent that edits the launchd/systemd user environment for `RV_*`, or
/// stops, unloads or kills rv's own service, weakens rv like `rv uninstall`.
@Suite("rv service self-protection")
struct ServiceSelfProtectionTests {
    static let weakening: [String] = [
        "launchctl setenv RV_GUARD_MODE observe",
        "launchctl setenv RV_JUDGE_ENGINE laya",
        "launchctl setenv PATH /usr/bin RV_LAYA_BUNDLE /tmp/x",
        "launchctl unsetenv RV_FT_BUNDLE",
        "launchctl setenv $NAME observe",
        "sudo launchctl setenv RV_GUARD_MODE observe",
        "bash -c 'launchctl setenv RV_GUARD_MODE observe'",
        "/bin/launchctl setenv RV_GUARD_MODE observe",
        "launchctl bootout gui/501/dev.rv.rvd",
        "launchctl bootout gui/501/dev.rv.evaluate",
        "launchctl bootout gui/501 ~/Library/LaunchAgents/dev.rv.evaluate.plist",
        "launchctl bootout gui/501",
        "launchctl bootout gui/$(id -u)/dev.rv.evaluate",
        "launchctl kill SIGKILL gui/501/dev.rv.evaluate",
        "launchctl kill 9 gui/501/dev.rv.mcp-custodian",
        "launchctl disable gui/501/dev.rv.evaluate",
        "launchctl remove dev.rv.evaluate",
        "launchctl unload ~/Library/LaunchAgents/dev.rv.evaluate.plist",
        "launchctl unload -w /Users/me/Library/LaunchAgents/dev.rv.evaluate.plist",
        "launchctl stop dev.rv.evaluate",
        "launchctl kickstart -k gui/501/dev.rv.evaluate",
        "launchctl kickstart -kp gui/501/dev.rv.evaluate",
        "launchctl bootout gui/501/$LABEL",
        "systemctl --user set-environment RV_GUARD_MODE=observe",
        "systemctl --user unset-environment RV_JUDGE_ENGINE",
        "systemctl --user import-environment",
        "systemctl --user import-environment RV_GUARD_MODE",
        "systemctl --user stop dev.rv.evaluate.service",
        "systemctl --user stop dev.rv.evaluate",
        "systemctl --user disable --now dev.rv.evaluate.service",
        "systemctl --user mask dev.rv.evaluate.service",
        "systemctl --user kill dev.rv.evaluate.service",
        "systemctl --user edit dev.rv.evaluate.service",
        "systemctl --user restart dev.rv.evaluate.service",
        "systemctl --user stop $UNIT",
        "pkill rvd",
        "pkill -9 rvd",
        "pkill -f rvd",
        "pkill -f '.local/bin/rvd'",
        "pkill rv",
        "pkill 'r.d'",
        "pkill .",
        "pkill -u me rvd",
        "killall rvd",
        "killall -9 rvd",
        "killall -m 'rv.*'",
        "kill $(pgrep rvd)",
        "kill -9 `pgrep -f rvd`",
        "pgrep rvd | xargs kill",
        "kill $(pidof rvd)",
        "sh -c 'pkill rvd'",
        "pkill $PROC",
        // Any non-read-only launchctl verb once an rv label or RV_* name appears.
        "launchctl asuser 501 launchctl setenv RV_GUARD_MODE observe",
        "launchctl bsexec 123 launchctl bootout gui/501/dev.rv.evaluate",
        "launchctl asuser 501 pkill rvd",
        "launchctl debug gui/501/dev.rv.evaluate --environment RV_JUDGE_ENGINE=laya",
        "launchctl bootstrap gui/501 /tmp/dev.rv.evaluate.plist",
        "launchctl submit -l dev.rv.evaluate -- /bin/sh",
        "launchctl attach gui/501/dev.rv.evaluate",
        "launchctl config user setenv RV_GUARD_MODE observe",
        // An unmodelled launcher before a kill or service tool.
        "lsof -ti:3000 | xargs kill",
        "find /tmp -name x -exec kill {} +",
        "caffeinate -i pkill node",
        "script -q /dev/null launchctl list",
        "arch -arm64 launchctl bootout gui/501/dev.rv.evaluate",
        "watch -n1 systemctl --user status",
        "unbuffer pkill rvd",
        "kill -9 -1",
        "kill -- -1",
    ]

    static let harmless: [String] = [
        "launchctl list",
        "launchctl print gui/501/dev.rv.evaluate",
        "launchctl setenv NODE_ENV production",
        "launchctl getenv RV_GUARD_MODE",
        "launchctl bootout gui/501/com.example.agent",
        "launchctl kickstart gui/501/dev.rv.evaluate",
        "launchctl kickstart -k gui/501/com.example.agent",
        "launchctl unload ~/Library/LaunchAgents/com.example.plist",
        "systemctl --user status dev.rv.evaluate.service",
        "systemctl --user start dev.rv.evaluate.service",
        "systemctl --user set-environment NODE_ENV=production",
        "systemctl --user stop nginx.service",
        "systemctl status",
        "pkill node",
        "pkill -f vite",
        "killall Finder",
        "pgrep rvd",
        "kill 12345",
        "kill $(pgrep node)",
        "echo pkill rvd",
        "git commit -m 'pkill rvd'",
        "launchctl print-disabled gui/501",
        "launchctl list | grep dev.rv",
        "launchctl blame gui/501/dev.rv.evaluate",
        "docker kill web",
        "npm run kill",
        "kill -1 12345",
    ]

    @Test("agent commands that retune or stop rv's service are flagged", arguments: weakening)
    func weakeningFlagged(command: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)), "\(command)")
    }

    @Test("a literal kill of rvd's pid at evaluation time is flagged", arguments: [
        "kill 4242", "kill -9 4242", "kill -s TERM 4242", "kill -TERM 1 4242", "/bin/kill 4242",
    ])
    func literalRVDPidFlagged(command: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command), rvdPIDs: { [4242] }), "\(command)")
    }

    @Test("a literal kill of another pid is not; an unknown rvd pid set fails closed")
    func literalOtherPid() {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: "kill 1234"), rvdPIDs: { [4242] }) == false)
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: "kill 1234"), rvdPIDs: { nil }))
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: "kill %1"), rvdPIDs: { nil }) == false)
    }

    @Test("evaluate floors a literal kill of rvd's injected pid; no injected pids fails closed")
    func evaluateUsesInjectedRVDPids() throws {
        let packs = [
            PackSnapshot(id: .coreGit, name: "git", description: "git", keywords: ["git"], safe: [], destructive: [
                DestructiveRule(name: "reset-hard", pattern: #"git\s+reset\s+--hard"#, severity: .critical, reason: "g"),
            ]),
            PackSnapshot(id: .coreFilesystem, name: "fs", description: "fs", keywords: ["rm"], safe: [], destructive: [
                DestructiveRule(name: "rm-rf", pattern: #"rm\s+-rf"#, severity: .high, reason: "r"),
            ]),
        ]
        let engine = ICUPatternEngine()
        let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
        func decision(_ command: String, rvdPIDs: (() -> Set<Int32>?)? = nil) -> Decision {
            let request = EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: [.coreFilesystem, .coreGit])
            guard let rvdPIDs else {
                return evaluate(request, packs: packs, engine: engine, compiled: compiled).decision
            }
            return evaluate(request, packs: packs, engine: engine, compiled: compiled, rvdPIDs: rvdPIDs).decision
        }
        #expect(decision("kill 4242", rvdPIDs: { [4242] }) == .indeterminate(.selfProtection))
        #expect(decision("kill 1234", rvdPIDs: { [4242] }) == .allow)
        #expect(decision("kill 1234", rvdPIDs: { nil }) == .indeterminate(.selfProtection))
        #expect(decision("kill 1234") == .indeterminate(.selfProtection))
    }

    @Test("unrelated service and process commands are not", arguments: harmless)
    func harmlessPass(command: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command), rvdPIDs: { [4242] }) == false, "\(command)")
    }
}
