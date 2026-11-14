import ArgumentParser
import RVDomain
import Testing
@testable import RVCLI

@Test func workspaceRunTimeoutParsesUnits() {
    #expect(WorkspaceRunTimeout.parse("90") == 90)
    #expect(WorkspaceRunTimeout.parse("90s") == 90)
    #expect(WorkspaceRunTimeout.parse("10m") == 600)
    #expect(WorkspaceRunTimeout.parse("2h") == 7_200)
    #expect(WorkspaceRunTimeout.parse("168h") == 604_800)
}

@Test(arguments: ["", "0", "0s", "169h", "-5", "+5", "1.5m", "5d", "m", "10 m", "99999999999999999h"])
func workspaceRunTimeoutRefusesMalformedOrOutOfRange(raw: String) {
    #expect(WorkspaceRunTimeout.parse(raw) == nil)
}

@Test func workspaceRunTimeoutResolvesAgainstThePolicyCeiling() throws {
    #expect(try WorkspaceRunTimeout.resolve(nil, microVM: false, policy: { nil }) == nil)
    #expect(try WorkspaceRunTimeout.resolve("30s", microVM: false, policy: { nil }) == 30)
    let ceiling = RuntimeProcessLimits(timeoutSeconds: 60)
    #expect(try WorkspaceRunTimeout.resolve("1m", microVM: false, policy: { ceiling }) == 60)
    #expect(throws: ValidationError.self) {
        try WorkspaceRunTimeout.resolve("2m", microVM: false, policy: { ceiling })
    }
    #expect(throws: ValidationError.self) {
        try WorkspaceRunTimeout.resolve("bogus", microVM: false, policy: { nil })
    }
    #expect(throws: ValidationError.self) {
        try WorkspaceRunTimeout.resolve("30s", microVM: true, policy: { nil })
    }
}

@Test func workspaceRunAcceptsTheTimeoutFlag() throws {
    let parsed = try WorkspaceRun.parse(["--timeout", "10m", "--", "/bin/sh", "-c", "true"])
    #expect(parsed.timeout == "10m")
    #expect(parsed.command.drop(while: { $0 == "--" }) == ["/bin/sh", "-c", "true"])
}

@Test func aRuntimeKilledAtItsDeadlineExits124WithAMessage() {
    let stopped = WorkspaceRunTimeout.outcome(status: 9, elapsed: .seconds(31), deadlineSeconds: 30)
    #expect(stopped.code == WorkspaceRunTimeout.timedOutExitCode)
    #expect(stopped.message == "rv: runtime stopped after its 30-second timeout\n")
    let exact = WorkspaceRunTimeout.outcome(status: 9, elapsed: .seconds(30), deadlineSeconds: 30)
    #expect(exact.code == 124)
}

@Test func otherEndingsKeepTheRuntimeStatus() {
    // (status, elapsed seconds, deadline): killed before the deadline is
    // someone else's SIGKILL; a clean or failing exit is the runtime's.
    let cases: [(Int32, Int64, UInt64?)] = [(9, 5, 30), (0, 40, 30), (1, 40, 30), (9, 40, nil)]
    for (status, elapsed, deadline) in cases {
        let reported = WorkspaceRunTimeout.outcome(status: status, elapsed: .seconds(elapsed), deadlineSeconds: deadline)
        #expect(reported.code == status)
        #expect(reported.message == nil)
    }
}
