import Testing
import RVPresentation
import RVTheme
@testable import RVCLI

@Test func setupCeremonyPlayer_zeroClock_emitsFinalCloserOnly() {
    let frames = setupCeremonyFrames(
        grok: .wired,
        pi: .pending,
        openCode: .pending,
        wrote: [.grok],
        kind: .install
    )!
    var written = ""
    let text = SetupCeremonyPlayer.play(
        frames: frames,
        palette: colorOffPalette,
        clock: ZeroSetupCeremonyClock(),
        animate: false,
        write: { written += $0 }
    )
    #expect(text.contains(setupCeremonyInstallCloser))
    #expect(written == text)
    #expect(text.contains("\u{001B}[") == false)
}

@Test func setupCeremonyPlayer_animate_rewritesWithCursorCodes() {
    let frames = [
        SetupCeremonyFrame(title: "A", pauseNanoseconds: 0),
        SetupCeremonyFrame(title: "B", closerLines: [setupCeremonyHooksWired], pauseNanoseconds: 0),
    ]
    var written = ""
    _ = SetupCeremonyPlayer.play(
        frames: frames,
        palette: colorOffPalette,
        clock: ZeroSetupCeremonyClock(),
        animate: true,
        write: { written += $0 }
    )
    #expect(written.contains("\u{001B}["))
    #expect(written.contains(setupCeremonyHooksWired))
}
