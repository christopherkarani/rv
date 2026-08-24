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
