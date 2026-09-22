import Testing
import RVDomain
@testable import RVService

struct EvaluateSessionTests {
    @Test func dayOneDeniesResetHard() {
        let session = EvaluateSession(enabledPacks: dayOnePackIDs)
        #expect(session.corePacksReady)
        let result = session.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git reset --hard"),
                enabledPacks: dayOnePackIDs
            )
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("day-one session must deny git reset --hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(result.matchingView == "git reset --hard")
    }

    @Test func dayOneAllowsStashDropAsAllowPlusMatch() {
        let session = EvaluateSession(enabledPacks: dayOnePackIDs)
        #expect(session.corePacksReady)
        let result = session.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git stash drop"),
                enabledPacks: dayOnePackIDs
            )
        )
        #expect(result.decision == .allow)
        #expect(result.matched?.ruleID.rawValue == "core.git:stash-drop")
    }

    @Test func nilEnabledPacksCompilesDayOneWithoutProcessHome() {
        let session = EvaluateSession()
        #expect(session.corePacksReady)
        #expect(Set(session.compiledPackIDs) == Set(dayOnePackIDs))
    }

    @Test func emptyWalkListOnSessionInitDoesNotUnionButCoverageDoes() {
        let walked = WalkedPackIDs(ids: [])
        let fromWalkIDs = EvaluateSession(enabledPacks: walked.ids)
        #expect(fromWalkIDs.compiledPackIDs.isEmpty)
        let fromCoverage = EvaluateSession(
            snapshots: nil,
            compiledPacks: PackCoverage.unioningDayOne(walked).compiled
        )
        #expect(Set(fromCoverage.compiledPackIDs) == Set(dayOnePackIDs))
    }

    @Test func emptyEnabledPacksDoesNotRefillDayOne() {
        let session = EvaluateSession(enabledPacks: dayOnePackIDs)
        #expect(session.corePacksReady)
        let result = session.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git reset --hard"),
                enabledPacks: []
            )
        )
        if case .deny = result.decision {
            Issue.record("empty enabledPacks means none enabled, not day-one refill")
        }
        #expect(result.decision == .allow)
    }

    @Test func missingCoreIsIndeterminateNotAllow() {
        let session = EvaluateSession.missingCore
        #expect(session.corePacksReady == false)
        let result = session.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git reset --hard"),
                enabledPacks: []
            )
        )
        #expect(result.decision == .indeterminate(.corePacksUnavailable))
        if case .allow = result.decision {
            Issue.record("missing core must never allow")
        }
    }

    @Test func evaluateWithSemantics_missingCore_staysIndeterminateAndAnalyzes() {
        let result = EvaluateSession.missingCore.evaluateWithSemantics(
            EvaluationRequest(
                command: ShellCommand(rawValue: "bash -c 'git reset --hard'"),
                enabledPacks: dayOnePackIDs
            )
        )
        #expect(result.decision == .indeterminate(.corePacksUnavailable))
        #expect(result.analysis.wrappers == [.bash])
        #expect(result.analysis.gitAction == .reset(mode: .hard, target: nil))
    }

    @Test func evaluateWithSemantics_missingCore_emptyCommand_isIndeterminateNotAllow() {
        let result = EvaluateSession.missingCore.evaluateWithSemantics(
            EvaluationRequest(
                command: ShellCommand(rawValue: "  "),
                enabledPacks: dayOnePackIDs
            )
        )
        #expect(result.decision == .indeterminate(.corePacksUnavailable))
    }

    /// Public product door is `evaluateWithSemantics`. Pack-only `evaluate` is
    /// package-visible so CLI/product callers cannot treat it as the door.
    @Test func publicProductDoor_isEvaluateWithSemantics() {
        let session = EvaluateSession()
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "bash -c 'git reset --hard'"),
            enabledPacks: dayOnePackIDs
        )
        let packOnly = session.evaluate(request)
        let door = session.evaluateWithSemantics(request)
        guard case .deny(let packDeny) = packOnly.decision else {
            Issue.record("pack-only evaluate must still deny git reset --hard")
            return
        }
        guard case .deny(let doorDeny) = door.decision else {
            Issue.record("public product door must deny, got \(door.decision)")
            return
        }
        #expect(packDeny.ruleID == doorDeny.ruleID)
        #expect(doorDeny.ruleID.rawValue == "core.git:reset-hard")
        #expect(door.analysis.wrappers == [.bash])
        #expect(door.analysis.gitAction == .reset(mode: .hard, target: nil))
    }

    @Test func evaluateWithSemantics_unwrapLimited_failClosed() {
        let result = EvaluateSession().evaluateWithSemantics(
            EvaluationRequest(
                command: ShellCommand(rawValue: #"python3 -c "$CMD""#),
                enabledPacks: dayOnePackIDs
            )
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("unreliable python must fail-closed, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID)
        #expect(result.analysis.innermost == .unwrapLimited)
    }

    @Test func uncompilableResetHardIsIndeterminateNotAllow() {
        let session = EvaluateSession.uncompilableCore
        #expect(session.corePacksReady == false)
        let result = session.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git reset --hard"),
                enabledPacks: []
            )
        )
        #expect(result.decision == .indeterminate(.corePacksUnavailable))
        if case .allow = result.decision {
            Issue.record("uncompilable required rule must never allow")
        }
    }
}
