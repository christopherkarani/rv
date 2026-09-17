import Testing
@testable import RVTheme

private func probe(
    stdin: Bool = true,
    stdout: Bool = true,
    json: Bool = false,
    robot: Bool = false,
    plain: Bool = false,
    noColorFlag: Bool = false,
    ci: Bool = false,
    noColorEnv: Bool = false,
    termDumb: Bool = false
) -> ThemeProbe {
    ThemeProbe(
        stdinIsTTY: stdin,
        stdoutIsTTY: stdout,
        jsonFlag: json,
        robotFlag: robot,
        plainFlag: plain,
        noColorFlag: noColorFlag,
        ci: ci,
        noColorEnv: noColorEnv,
        termDumb: termDumb
    )
}

private struct ModeCase {
    var name: String
    var probe: ThemeProbe
    var requested: RequestedMode
    var mode: OutputMode
    var colors: Bool
}

@Test func outputMode_table() {
    let cases: [ModeCase] = [
        ModeCase(
            name: "both-tty-automatic",
            probe: probe(),
            requested: .automatic,
            mode: .pretty,
            colors: true
        ),
        ModeCase(
            name: "json-flag-forces-robot",
            probe: probe(json: true),
            requested: .automatic,
            mode: .robot,
            colors: false
        ),
        ModeCase(
            name: "requested-robot",
            probe: probe(),
            requested: .robot,
            mode: .robot,
            colors: false
        ),
        ModeCase(
            name: "stdin-only-tty",
            probe: probe(stdout: false),
            requested: .automatic,
            mode: .robot,
            colors: false
        ),
        ModeCase(
            name: "stdout-only-tty-automatic",
            probe: probe(stdin: false),
            requested: .automatic,
            mode: .pretty,
            colors: true
        ),
        ModeCase(
            name: "piped-automatic-robot",
            probe: probe(stdin: false, stdout: false),
            requested: .automatic,
            mode: .robot,
            colors: false
        ),
        ModeCase(
            name: "term-dumb-pretty-no-color",
            probe: probe(termDumb: true),
            requested: .automatic,
            mode: .pretty,
            colors: false
        ),
        ModeCase(
            name: "requested-pretty",
            probe: probe(stdout: false),
            requested: .pretty,
            mode: .pretty,
            colors: false
        ),
    ]

    for item in cases {
        let resolved = OutputMode(probe: item.probe, requested: item.requested)
        #expect(resolved == item.mode, Comment(rawValue: item.name))
        #expect(
            ColorCapability(probe: item.probe, mode: resolved).colorsEnabled == item.colors,
            Comment(rawValue: item.name)
        )
    }
}

@Test func themeProbe_composesTTYAndForbid() {
    let probe = probe(json: true, ci: true, noColorEnv: true)
    #expect(probe.terminal.stdinIsTTY)
    #expect(probe.terminal.stdoutIsTTY)
    #expect(probe.terminal.isBrowseEligible)
    #expect(probe.forbid.json)
    #expect(probe.forbid.ci)
    #expect(probe.forbid.noColor.env)
    #expect(probe.forbid.isBrowseEligible == false)
    #expect(probe.isBrowseEligible == false)
}

@Test func outputForbid_noColorFlagKeepsBrowseKillsColor() {
    let forbid = OutputForbid(
        json: false,
        robot: false,
        plain: false,
        ci: false,
        noColor: OutputForbid.NoColor(flag: true, env: false, termDumb: false)
    )
    #expect(forbid.isBrowseEligible)
    #expect(forbid.canCarryColor == false)
    #expect(forbid.noColor.env == false)
    #expect(forbid.noColor.canCarryColor == false)
}

@Test func palette_colorOff_hasNoEscape() {
    let off = Palette(for: ColorCapability(colorsEnabled: false))
    #expect(off.colorsEnabled == false)
    #expect(off.reset.isEmpty)
    #expect(off.fact.isEmpty)
    #expect(off.muted.isEmpty)
    #expect(off.deny.isEmpty)
    #expect(off.allow.isEmpty)
    #expect(off.heading.isEmpty)
    #expect(off.mark.isEmpty)
    #expect(off.trace.isEmpty)
    #expect(off.silver.isEmpty)
    #expect(off.regex == .off)
    #expect(off.reset.contains("\u{001B}") == false)
}

@Test func themeProbe_clampsColumnsAndExposesFlags() {
    let probe = ThemeProbe(
        stdinIsTTY: false,
        stdoutIsTTY: true,
        jsonFlag: false,
        robotFlag: true,
        plainFlag: true,
        noColorFlag: true,
        ci: false,
        noColorEnv: false,
        termDumb: true,
        columns: 8
    )
    #expect(probe.columns == 16)
    #expect(probe.stdinIsTTY == false)
    #expect(probe.stdoutIsTTY)
    #expect(probe.jsonFlag == false)
    #expect(probe.robotFlag)
    #expect(probe.plainFlag)
    #expect(probe.noColorFlag)
    #expect(probe.ci == false)
    #expect(probe.noColorEnv == false)
    #expect(probe.termDumb)
    #expect(probe.terminal.canCarryColor)
    #expect(probe.forbid.isBrowseEligible == false)
    #expect(probe.forbid.canCarryColor == false)
    #expect(probe.isBrowseEligible == false)
}

@Test func themeProbe_composedInitAndDeprecatedWrappers() {
    let terminal = TTYPair(stdinIsTTY: true, stdoutIsTTY: false)
    let forbid = OutputForbid(
        json: false,
        robot: false,
        plain: false,
        ci: true,
        noColor: OutputForbid.NoColor(flag: false, env: false, termDumb: false)
    )
    let probe = ThemeProbe(terminal: terminal, forbid: forbid, columns: 120)
    #expect(probe.columns == 120)
    #expect(probe.terminal.isBrowseEligible == false)
    #expect(forbid.canCarryColor == false)
    #expect(resolveOutputMode(probe: probe, requested: .automatic) == .robot)
    #expect(colorCapability(probe: probe, mode: .pretty).colorsEnabled == false)
    #expect(palette(for: ColorCapability(colorsEnabled: false)) == colorOffPalette)
}

@Test func outputForbid_robotKeepsColorUntilPlainOrCI() {
    let robot = OutputForbid(
        json: false,
        robot: true,
        plain: false,
        ci: false,
        noColor: OutputForbid.NoColor(flag: false, env: false, termDumb: false)
    )
    #expect(robot.isBrowseEligible == false)
    #expect(robot.canCarryColor)
}

@Test func colorCapability_prettyUsesProbeColor() {
    let probe = probe()
    #expect(ColorCapability(probe: probe, mode: .pretty).colorsEnabled)
    #expect(ColorCapability(probe: probe, mode: .robot).colorsEnabled == false)
}

@Test func palette_colorOn_usesNamedSlotsOnly() {
    let on = Palette(for: ColorCapability(colorsEnabled: true))
    #expect(on.colorsEnabled)
    #expect(on.reset.contains("\u{001B}"))
    #expect(on.deny.contains("\u{001B}"))
    #expect(on.heading.contains("\u{001B}"))
    #expect(on.mark.contains("\u{001B}"))
    #expect(on.trace.contains("\u{001B}"))
    #expect(on.silver.contains("\u{001B}"))
    #expect(on.silver != on.heading)
    #expect(on.heading != on.mark)
    #expect(on.mark != on.trace)
    #expect(on.regex.meta.contains("\u{001B}"))
    #expect(on.regex.escape.contains("\u{001B}"))
    #expect(on.regex.name.contains("\u{001B}"))
}
