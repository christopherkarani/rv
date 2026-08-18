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
    var browse: Bool
}

@Test func outputMode_table() {
    let cases: [ModeCase] = [
        ModeCase(
            name: "both-tty-automatic",
            probe: probe(),
            requested: .automatic,
            mode: .pretty,
            colors: true,
            browse: true
        ),
        ModeCase(
            name: "both-tty-browse",
            probe: probe(),
            requested: .browse,
            mode: .browse,
            colors: true,
            browse: true
        ),
        ModeCase(
            name: "json-flag-forces-robot",
            probe: probe(json: true),
            requested: .automatic,
            mode: .robot,
            colors: false,
            browse: false
        ),
        ModeCase(
            name: "robot-flag-forces-robot",
            probe: probe(robot: true),
            requested: .browse,
            mode: .robot,
            colors: false,
            browse: false
        ),
        ModeCase(
            name: "requested-robot",
            probe: probe(),
            requested: .robot,
            mode: .robot,
            colors: false,
            browse: true
        ),
        ModeCase(
            name: "plain-stays-pretty-not-browse",
            probe: probe(plain: true),
            requested: .browse,
            mode: .pretty,
            colors: false,
            browse: false
        ),
        ModeCase(
            name: "ci-browse-falls-back-pretty",
            probe: probe(ci: true),
            requested: .browse,
            mode: .pretty,
            colors: false,
            browse: false
        ),
        ModeCase(
            name: "nocolor-env-forbids-browse",
            probe: probe(noColorEnv: true),
            requested: .browse,
            mode: .pretty,
            colors: false,
            browse: false
        ),
        ModeCase(
            name: "stdin-only-tty",
            probe: probe(stdout: false),
            requested: .automatic,
            mode: .robot,
            colors: false,
            browse: false
        ),
        ModeCase(
            name: "stdout-only-tty-automatic",
            probe: probe(stdin: false),
            requested: .automatic,
            mode: .pretty,
            colors: true,
            browse: false
        ),
        ModeCase(
            name: "stdout-only-tty-browse-fallback",
            probe: probe(stdin: false),
            requested: .browse,
            mode: .pretty,
            colors: true,
            browse: false
        ),
        ModeCase(
            name: "piped-automatic-robot",
            probe: probe(stdin: false, stdout: false),
            requested: .automatic,
            mode: .robot,
            colors: false,
            browse: false
        ),
        ModeCase(
            name: "term-dumb-pretty-no-color",
            probe: probe(termDumb: true),
            requested: .automatic,
            mode: .pretty,
            colors: false,
            browse: true
        ),
        ModeCase(
            name: "no-color-flag-browse-still-eligible",
            probe: probe(noColorFlag: true),
            requested: .browse,
            mode: .browse,
            colors: false,
            browse: true
        ),
        ModeCase(
            name: "requested-pretty",
            probe: probe(stdout: false),
            requested: .pretty,
            mode: .pretty,
            colors: false,
            browse: false
        ),
    ]

    for item in cases {
        #expect(browseEligible(item.probe) == item.browse, Comment(rawValue: item.name))
        #expect(
            resolveOutputMode(probe: item.probe, requested: item.requested) == item.mode,
            Comment(rawValue: item.name)
        )
        let resolved = resolveOutputMode(probe: item.probe, requested: item.requested)
        #expect(
            colorCapability(probe: item.probe, mode: resolved).colorsEnabled == item.colors,
            Comment(rawValue: item.name)
        )
        #expect(
            OutputMode(probe: item.probe, requested: item.requested) == item.mode,
            Comment(rawValue: item.name)
        )
        #expect(
            ColorCapability(probe: item.probe, mode: resolved).colorsEnabled == item.colors,
            Comment(rawValue: item.name)
        )
        #expect(item.probe.isBrowseEligible == item.browse, Comment(rawValue: item.name))
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
