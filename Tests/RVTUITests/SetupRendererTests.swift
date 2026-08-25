import Testing
import RVPresentation
import RVTheme
@testable import RVTUI

private func hostlessFrame() -> SetupCeremonyFrame {
    SetupCeremonyFrame(
        activity: setupCeremonySearchActivity,
        slots: SetupHostKind.allCases.map { SetupSlotView(host: $0, kind: .pending) },
        closerLines: [setupCeremonyHostlessTitle, setupCeremonyHostlessNext]
    )
}

private func grokWiredFrame() -> SetupCeremonyFrame {
    SetupCeremonyFrame(
        title: setupCeremonyWiringTitle,
        slots: [
            SetupSlotView(host: .grok, kind: .wired, clause: setupGrokReloadClause),
            SetupSlotView(host: .pi, kind: .pending),
            SetupSlotView(host: .openCode, kind: .pending),
            SetupSlotView(host: .claude, kind: .pending),
        ],
        closerLines: [setupCeremonyHooksWired]
    )
}

@Test func setupRenderer_hostless_colorOff_matchesCloser() {
    let lines = SetupRenderer().render(hostlessFrame(), palette: colorOffPalette)
    #expect(lines.contains(SetupRenderer.leadingPad + "◦  Grok"))
    #expect(lines.contains(SetupRenderer.leadingPad + "◦  Pi"))
    #expect(lines.contains(SetupRenderer.leadingPad + "◦  OpenCode"))
    #expect(lines.contains(SetupRenderer.leadingPad + "◦  Claude"))
    #expect(lines.contains(SetupRenderer.leadingPad + setupCeremonySearchActivity))
    #expect(lines.contains(SetupRenderer.leadingPad + setupCeremonyHostlessTitle))
    #expect(lines.contains(SetupRenderer.leadingPad + setupCeremonyHostlessNext))
    #expect(lines.allSatisfy { $0.contains("\u{001B}") == false })
}

@Test func setupRenderer_wiredGrok_squareAndHooksWired() {
    let lines = SetupRenderer().render(grokWiredFrame(), palette: colorOffPalette)
    #expect(lines.contains(SetupRenderer.leadingPad + "•  Grok  reload /hooks"))
    #expect(lines.contains(SetupRenderer.leadingPad + "◦  Pi"))
    #expect(lines.contains(SetupRenderer.leadingPad + setupCeremonyWiringTitle))
    #expect(lines.contains(SetupRenderer.leadingPad + setupCeremonyHooksWired))
}

@Test func setupRenderer_markOnlyColor_textUnpainted() {
    let palette = Palette(for: ColorCapability(colorsEnabled: true))
    let lines = SetupRenderer().render(grokWiredFrame(), palette: palette)
    let grok = lines.first { $0.contains("Grok") }!
    let pi = lines.first { $0.contains("Pi") }!
    #expect(grok.hasPrefix(SetupRenderer.leadingPad + palette.heading + "•" + palette.reset + "  Grok"))
    #expect(pi.hasPrefix(SetupRenderer.leadingPad + palette.muted + "◦" + palette.reset + "  Pi"))
    #expect(grok.contains(palette.heading + "Grok") == false)
}

@Test func setupRenderer_progressBar_thinRulesAndPad() {
    let lines = SetupRenderer().render(
        SetupCeremonyFrame(title: setupCeremonyDownloadTitle, progress: 0.5),
        palette: colorOffPalette
    )
    #expect(lines.contains(SetupRenderer.leadingPad + setupCeremonyDownloadTitle))
    let bar = lines.first { $0.contains("━") }!
    #expect(bar.hasPrefix(SetupRenderer.leadingPad))
    let body = String(bar.dropFirst(SetupRenderer.leadingPad.count))
    #expect(body.count == SetupRenderer.progressWidth)
    #expect(body.filter { $0 == "━" }.count == 12)
    #expect(body.filter { $0 == "─" }.count == 12)
    #expect(body.contains("█") == false)
}
