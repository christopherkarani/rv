import Testing
import RVPresentation
import RVTheme
@testable import RVTUI

private func hostlessModel(isQuiet: Bool = false) -> SetupViewModel {
    SetupViewModel(
        slots: SetupHostKind.allCases.map { SetupSlotView(host: $0, kind: .pending) },
        activity: "looking for hosts",
        closerTitle: "No hosts yet",
        closerNext: "Next  rv setup",
        isQuiet: isQuiet
    )
}

private func grokWiredModel() -> SetupViewModel {
    SetupViewModel(
        slots: [
            SetupSlotView(host: .grok, kind: .wired, clause: "reload /hooks"),
            SetupSlotView(host: .pi, kind: .pending),
            SetupSlotView(host: .openCode, kind: .pending),
        ],
        activity: "wiring Grok",
        closerTitle: "Setup complete",
        closerNext: "Next  rv test 'git reset --hard'",
        isQuiet: false
    )
}

@Test func setupRenderer_hostless_colorOff_matchesCloser() {
    let lines = SetupRenderer().render(hostlessModel(), palette: colorOffPalette)
    #expect(lines == [
        "○ Grok",
        "○ Pi",
        "○ OpenCode",
        "looking for hosts",
        "No hosts yet",
        "Next  rv setup",
    ])
    #expect(lines.allSatisfy { $0.contains("\u{001B}") == false })
}

@Test func setupRenderer_quiet_isEmpty() {
    let lines = SetupRenderer().render(hostlessModel(isQuiet: true), palette: colorOffPalette)
    #expect(lines.isEmpty)
}

@Test func setupRenderer_wiredGrok_colorOff_reloadIsClause() {
    let lines = SetupRenderer().render(grokWiredModel(), palette: colorOffPalette)
    #expect(lines == [
        "● Grok  reload /hooks",
        "○ Pi",
        "○ OpenCode",
        "wiring Grok",
        "Setup complete",
        "Next  rv test 'git reset --hard'",
    ])
}

@Test func setupRenderer_circleOnlyColor_textUnpainted() {
    let palette = Palette(for: ColorCapability(colorsEnabled: true))
    let lines = SetupRenderer().render(grokWiredModel(), palette: palette)
    let grok = lines[0]
    let pi = lines[1]
    #expect(grok.hasPrefix(palette.heading + "●" + palette.reset + " Grok"))
    #expect(pi.hasPrefix(palette.muted + "○" + palette.reset + " Pi"))
    #expect(grok.contains(palette.heading + "Grok") == false)
    #expect(lines[3] == "wiring Grok")
    #expect(lines[4] == "Setup complete")
    #expect(lines.contains(where: { $0.contains("Result:") }) == false)
    #expect(lines.contains(where: { $0.contains("BLOCKED") }) == false)
}
