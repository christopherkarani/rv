import Testing
import RVPresentation
import RVTheme
@testable import RVTUI

@Test func helpRenderer_root_colorOff_hasGroupsAndNext() {
    let model = HelpViewModel(
        title: "rv",
        blurb: "Block destructive shell commands.",
        sections: [
            HelpSection(
                heading: "Get started",
                rows: [
                    HelpRow(name: "setup", description: "Wire host hooks and start rvd"),
                    HelpRow(name: "test", description: "Try a command before it runs"),
                ],
                accentNames: true
            ),
            HelpSection(heading: "Everyday", rows: [
                HelpRow(name: "explain", description: "Why something was allowed or blocked"),
            ]),
        ],
        examples: ["rv setup"],
        next: [
            HelpNextItem(command: "rv help test", description: "Flags and usage for test"),
        ]
    )
    let lines = HelpRenderer().render(model, palette: colorOffPalette)
    #expect(lines[0] == "rv  Block destructive shell commands.")
    #expect(lines.contains("Get started"))
    #expect(lines.contains("  setup  Wire host hooks and start rvd"))
    #expect(lines.contains("Examples"))
    #expect(lines.contains("  → rv setup"))
    #expect(lines.contains("Next"))
    #expect(lines.contains("  rv help test  Flags and usage for test"))
    #expect(lines.allSatisfy { $0.contains("\u{001B}") == false })
    #expect(lines.allSatisfy { $0.contains("$") == false })
}

@Test func helpRenderer_root_colorOn_greenOnlyOnGetStarted() {
    let model = HelpViewModel(
        title: "rv",
        blurb: "Block destructive shell commands.",
        sections: [
            HelpSection(
                heading: "Get started",
                rows: [
                    HelpRow(name: "setup", description: "Wire host hooks"),
                ],
                accentNames: true
            ),
            HelpSection(heading: "Everyday", rows: [
                HelpRow(name: "explain", description: "Why something was blocked"),
            ]),
        ],
        examples: ["rv setup"],
        next: [
            HelpNextItem(command: "rv help test", description: "Flags and usage for test"),
        ]
    )
    let palette = Palette(for: ColorCapability(colorsEnabled: true))
    let lines = HelpRenderer().render(model, palette: palette)

    let setup = lines.first { $0.contains("setup") && $0.contains("Wire host hooks") }
    #expect(setup?.contains(palette.allow) == true)
    #expect(setup?.contains(palette.heading) == false)

    let explain = lines.first { $0.contains("explain") && $0.contains("Why something") }
    #expect(explain?.contains(palette.fact) == true)
    #expect(explain?.contains(palette.allow) == false)
    #expect(explain?.contains(palette.heading) == false)

    let example = lines.first { $0.contains("→") }
    #expect(example?.contains(palette.silver) == true)
    #expect(example?.contains(palette.allow) == false)
    #expect(example?.contains(palette.heading) == false)

    let next = lines.first { $0.contains("rv help test") }
    #expect(next?.contains(palette.fact) == true)
    #expect(next?.contains(palette.allow) == false)
}
