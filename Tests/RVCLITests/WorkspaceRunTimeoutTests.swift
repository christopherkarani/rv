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
