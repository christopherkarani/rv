import Testing
import RVTheme
@testable import RVCLI

@Test func cliAppearance_ciForcesRobot_evenWhenTTYWouldBePretty() {
    let appearance = CLIAppearance.resolve(
        probe: operatorProbe(ci: true, stdoutIsTTY: true),
        requested: .automatic
    )
    #expect(appearance == .robot)
}

@Test func cliAppearance_ttyAutomaticWithoutCIIsPretty() {
    let probe = operatorProbe(ci: false, stdoutIsTTY: true, noColor: true)
    let appearance = CLIAppearance.resolve(probe: probe, requested: .automatic)
    #expect(appearance == .pretty(colorOffPalette))
}

@Test func cliAppearance_robotFlagIsRobot() {
    let appearance = CLIAppearance.resolve(
        probe: operatorProbe(robot: true, stdoutIsTTY: true),
        requested: .robot
    )
    #expect(appearance == .robot)
}

@Test func serviceStatus_textFollowsAppearance() {
    let report = ServiceStatusReport(state: "down", fallback: "down")
    #expect(ServiceStatusCommand.text(report, appearance: .robot) == ServiceStatusCommand.robotText(report))
    #expect(
        ServiceStatusCommand.text(report, appearance: .pretty(colorOffPalette))
            == ServiceStatusCommand.plainText(report)
    )
}

private func operatorProbe(
    json: Bool = false,
    robot: Bool = false,
    ci: Bool = false,
    stdoutIsTTY: Bool,
    noColor: Bool = false
) -> ThemeProbe {
    ThemeProbe(
        terminal: TTYPair(stdinIsTTY: true, stdoutIsTTY: stdoutIsTTY),
        forbid: OutputForbid(
            json: json,
            robot: robot,
            plain: false,
            ci: ci,
            noColor: OutputForbid.NoColor(flag: noColor, env: false, termDumb: false)
        )
    )
}
