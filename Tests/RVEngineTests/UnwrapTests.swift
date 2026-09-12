import Testing
import RVDomain
@testable import RVEngine

@Suite("Unwrap")
struct UnwrapTests {
    @Test func bashDashC_extractsInnerCommand() {
        let outcome = unwrapCommand(ShellCommand(rawValue: "bash -c 'git reset --hard'"))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("expected complete unwrap")
            return
        }
        #expect(unwrapped.command.rawValue == "git reset --hard")
        #expect(unwrapped.layers == [.bash])
    }

    @Test func sudoEnvSh_preservesInnerAndRecordsLayers() {
        let outcome = unwrapCommand(
            ShellCommand(rawValue: "sudo env FOO=bar sh -c 'git reset --hard'")
        )
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("expected complete unwrap, got \(outcome)")
            return
        }
        #expect(unwrapped.command.rawValue == "git reset --hard")
        #expect(unwrapped.layers == [.sudo, .env, .sh])
    }

    @Test func envChdir_updatesWorkingDirectory() {
        let cwd = WorkingDirectory(validating: "/repo")
        let outcome = unwrapCommand(
            ShellCommand(rawValue: "env -C /tmp rm file"),
            workingDirectory: cwd
        )
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("expected complete unwrap")
            return
        }
        #expect(unwrapped.command.rawValue == "rm file")
        #expect(unwrapped.layers == [.env])
        #expect(unwrapped.workingDirectory?.rawValue == "/tmp")
    }

    @Test func zshDashC_extractsInnerCommand() {
        let outcome = unwrapCommand(ShellCommand(rawValue: "zsh -c 'git reset --hard'"))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("expected complete unwrap")
            return
        }
        #expect(unwrapped.command.rawValue == "git reset --hard")
        #expect(unwrapped.layers == [.zsh])
    }

    @Test func commandWrapper_peelsToInner() {
        let outcome = unwrapCommand(ShellCommand(rawValue: "command git reset --hard"))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("expected complete unwrap")
            return
        }
        #expect(unwrapped.command.rawValue == "git reset --hard")
        #expect(unwrapped.layers == [.command])
    }

    @Test func echoQuotedRm_isNotUnwrapped() {
        let outcome = unwrapCommand(ShellCommand(rawValue: "echo 'rm -rf /'"))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("expected complete")
            return
        }
        #expect(unwrapped.command.rawValue == "echo 'rm -rf /'")
        #expect(unwrapped.layers.isEmpty)
    }

    @Test func pythonPrint_isDataOnly() {
        let outcome = unwrapCommand(
            ShellCommand(rawValue: #"python -c "print('rm -rf /')""#)
        )
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("expected complete")
            return
        }
        #expect(unwrapped.layers.isEmpty)
        #expect(unwrapped.command.rawValue.contains("print"))
    }

    @Test func pythonOsSystem_extractsShell() {
        let outcome = unwrapCommand(
            ShellCommand(rawValue: #"python -c "os.system('git reset --hard')""#)
        )
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("expected complete, got \(outcome)")
            return
        }
        #expect(unwrapped.command.rawValue == "git reset --hard")
        #expect(unwrapped.layers == [.python])
    }

    @Test func nodeExecSync_extractsShell() {
        let outcome = unwrapCommand(
            ShellCommand(
                rawValue: #"node -e "require('child_process').execSync('git reset --hard')""#
            )
        )
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("expected complete, got \(outcome)")
            return
        }
        #expect(unwrapped.command.rawValue == "git reset --hard")
        #expect(unwrapped.layers == [.node])
    }

    @Test func rubySystem_extractsShell() {
        let outcome = unwrapCommand(
            ShellCommand(rawValue: #"ruby -e "system('rm -rf Sources')""#)
        )
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("expected complete, got \(outcome)")
            return
        }
        #expect(unwrapped.command.rawValue == "rm -rf Sources")
        #expect(unwrapped.layers == [.ruby])
    }

    @Test func depthLimit_isLimitedNotComplete() {
        let outcome = unwrapCommand(
            ShellCommand(rawValue: "sudo env bash -c 'git reset --hard'"),
            maxDepth: 2
        )
        guard case .limited(let layers) = outcome else {
            Issue.record("expected limited, got \(outcome)")
            return
        }
        #expect(layers.contains(.bash))
    }

    @Test func sizeLimit_isLimitedNotComplete() {
        let payload = String(repeating: "x", count: 200)
        let outcome = unwrapCommand(
            ShellCommand(rawValue: "bash -c '\(payload)'"),
            maxBytes: 50
        )
        guard case .limited = outcome else {
            Issue.record("expected limited, got \(outcome)")
            return
        }
    }

    @Test(arguments: [
        #"python3 -c "x=1""#,
        #"python3 -c "print(1)""#,
        #"python3 -c "import os, json, sys""#,
        #"python3 -c "import json,sys; json.dump({}, sys.stdout)""#,
        #"python3 -c "from pathlib import Path; print(Path('.').resolve())""#,
        #"python3 -c "mystery(payload)""#,
        #"python -c "mystery(payload)""#,
        #"node -e "JSON.parse('{}')""#,
        #"node -e "console.log(1)""#,
    ])
    func interpreterDataOnly_isCompleteWithoutExtractedShell(_ raw: String) {
        let outcome = unwrapCommand(ShellCommand(rawValue: raw))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("data-only interpreter must complete, got \(outcome) for \(raw)")
            return
        }
        #expect(unwrapped.layers.isEmpty)
        #expect(unwrapped.command.rawValue == raw)
    }

    @Test(arguments: [
        #"python -c "os.system(x)""#,
        #"python -c "os.popen(x)""#,
        #"python -c "subprocess.run(x)""#,
        #"python -c "shutil.rmtree(x)""#,
        #"node -e "child_process.exec(x)""#,
        #"node -e "child_process.execSync(x)""#,
        #"node -e "require('child_process').exec(x)""#,
    ])
    func unparseableInterpreterSpawn_isLimited(_ raw: String) {
        let outcome = unwrapCommand(ShellCommand(rawValue: raw))
        guard case .limited(let layers) = outcome else {
            Issue.record("unparseable spawn must be limited, got \(outcome) for \(raw)")
            return
        }
        #expect(layers == (raw.hasPrefix("node") ? [.node] : [.python]))
    }

    @Test func pythonOpenWrite_peelsToRedirect() {
        let outcome = unwrapCommand(
            ShellCommand(rawValue: #"python3 -c "open('foo','w').write('x')""#)
        )
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("open write must peel to a redirect, got \(outcome)")
            return
        }
        #expect(unwrapped.layers == [.python])
        #expect(unwrapped.command.rawValue.contains("foo"))
        #expect(unwrapped.command.rawValue.contains(">"))
        #expect(unwrapped.command.rawValue.contains("open(") == false)
    }

    @Test func unparseablePythonOpenWrite_isLimited() {
        let outcome = unwrapCommand(ShellCommand(rawValue: #"python -c "open(path, 'w')""#))
        guard case .limited(let layers) = outcome else {
            Issue.record("unparseable open write must be limited, got \(outcome)")
            return
        }
        #expect(layers == [.python])
    }

    @Test func unquotedBashDashC_isLimited() {
        let outcome = unwrapCommand(ShellCommand(rawValue: "bash -c git reset --hard"))
        guard case .limited(let layers) = outcome else {
            Issue.record("unquoted -c must be limited, got \(outcome)")
            return
        }
        #expect(layers == [.bash])
    }

    @Test func dollarPayloadDashC_isLimited() {
        let outcome = unwrapCommand(ShellCommand(rawValue: "bash -c $CMD"))
        guard case .limited(let layers) = outcome else {
            Issue.record("$ -c payload must be limited, got \(outcome)")
            return
        }
        #expect(layers == [.bash])
    }

    @Test func ansiCQuotedDashC_isLimited() {
        let outcome = unwrapCommand(ShellCommand(rawValue: "sh -c $'git reset --hard'"))
        guard case .limited(let layers) = outcome else {
            Issue.record("$'…' -c must be limited, got \(outcome)")
            return
        }
        #expect(layers == [.sh])
    }

    @Test func pythonPrintOsSystem_extractsShell() {
        let outcome = unwrapCommand(
            ShellCommand(rawValue: #"python -c "print(os.system('git reset --hard'))""#)
        )
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("print(os.system) must extract or limit, got \(outcome)")
            return
        }
        #expect(unwrapped.command.rawValue == "git reset --hard")
        #expect(unwrapped.layers == [.python])
    }
}
