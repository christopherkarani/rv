import Testing
import RVDomain
import RVEngine

/// Door / unwrap / peel stress. Pin `evaluate` is the scoreboard; the product
/// door is `evaluateWithSemantics`. Wrapper depth, option soup, unquoted `-c`,
/// and heredoc-to-file (not `cat <<EOF | bash`).
///
/// Run: `tools/gate.sh --quiet RVCorpusTests --filter DoorUnwrapStress`
@Suite("Door unwrap peel stress")
struct DoorUnwrapStressTests {
    @Test func door_wrapperDepth_peelsQuietStatus() throws {
        let harness = try StressHarness.dayOne()
        let command = "timeout 10 nice -n 5 env FOO=1 bash -c 'git status'"
        let pin = harness.pin(command)
        #expect(pin.decision == .allow, "pin must allow quiet wrapped status, got \(describeDecision(pin))")
        let door = harness.door(command)
        #expect(door.decision == .allow, "door over-block \(describeDecision(door))")
        #expect(door.analysis.wrappers == [.timeout, .nice, .env, .bash])
    }

    @Test func door_wrapperDepth_keepsResetHardFloor() throws {
        let harness = try StressHarness.dayOne()
        let command = "timeout 10 nice env FOO=1 bash -c 'git reset --hard'"
        let pin = harness.pin(command)
        guard case .deny(let pinDeny) = pin.decision else {
            Issue.record("wrapped reset must still pin-deny, got \(describeDecision(pin))")
            return
        }
        #expect(pinDeny.ruleID.rawValue == "core.git:reset-hard")
        let door = harness.door(command)
        guard case .deny(let deny) = door.decision else {
            Issue.record("door must keep pack deny floor, got \(describeDecision(door))")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(door.analysis.wrappers == [.timeout, .nice, .env, .bash])
    }

    @Test func unwrap_maxDepth_isLimited() {
        let inner = "git status"
        var layered = inner
        for _ in 0..<UnwrapLimits.maxDepth + 1 {
            layered = "bash -c '\(layered.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        let outcome = unwrapCommand(ShellCommand(rawValue: layered))
        guard case .limited = outcome else {
            Issue.record("depth \(UnwrapLimits.maxDepth + 1) must be limited, got \(outcome)")
            return
        }
    }

    @Test func unwrap_optionSoup_peelsTimeoutNiceMiseSSH() {
        let command =
            "timeout --foreground --verbose -k 2s --signal=TERM 1 nice -n 10 mise exec -- ssh -p 22 example 'git status'"
        let outcome = unwrapCommand(ShellCommand(rawValue: command))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("option soup must complete, got \(outcome)")
            return
        }
        #expect(unwrapped.command.rawValue == "git status")
        #expect(unwrapped.layers == [.timeout, .nice, .mise, .ssh])
    }

    @Test func door_unquotedDashC_isUnwrapLimited() throws {
        let harness = try StressHarness.dayOne()
        let command = "bash -c git status"
        #expect(harness.pin(command).decision == .allow)
        let door = harness.door(command)
        guard case .deny(let deny) = door.decision else {
            Issue.record("unquoted -c must unwrap-limited-deny, got \(describeDecision(door))")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID)
    }

    @Test func door_heredocWrite_allowsDataBody() throws {
        let harness = try StressHarness.dayOne()
        let command = """
            cat > /tmp/note.md << 'EOF'
            See git reset --hard
            EOF
            """
        #expect(harness.pin(command).decision == .allow)
        let door = harness.door(command)
        #expect(door.decision == .allow, "door over-block \(describeDecision(door)) on heredoc write")
        #expect(door.analysis.gitAction == nil)
    }

    @Test func door_heredocPipeBash_stillDeniesInnerReset() throws {
        let harness = try StressHarness.dayOne()
        let command = """
            cat <<'EOF' | bash
            git reset --hard
            EOF
            """
        let door = harness.door(command)
        guard case .deny(let deny) = door.decision else {
            Issue.record("heredoc | bash must deny, got \(describeDecision(door))")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(door.analysis.wrappers == [.bash])
        #expect(door.analysis.innermost == .git(.reset(mode: .hard, target: nil)))
    }
}
