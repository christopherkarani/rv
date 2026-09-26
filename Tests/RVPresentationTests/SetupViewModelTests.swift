import Testing
import RVDomain
@testable import RVPresentation

@Test func setupSlotSnapshot_wiredCodex_usesTrustClause() {
    let slots = SetupSlotSnapshot(
        grok: .skipped,
        pi: .skipped,
        openCode: .skipped,
        codex: .wired,
        wrote: [.codex]
    )
    #expect(slots.kind(for: .codex) == .wired)
    #expect(setupSlotClause(host: .codex, kind: .wired) == setupCodexTrustClause)
    #expect(slots.slotViews.contains { $0.host == .codex && $0.clause == setupCodexTrustClause })
}

@Test func hookHost_robotSkipLinesCoverEveryHost() {
    #expect(HookHost.grok.robotSkipLine.contains("grok"))
    #expect(HookHost.pi.robotSkipLine.contains("pi"))
    #expect(HookHost.opencode.robotSkipLine.contains("opencode"))
    #expect(HookHost.claude.robotSkipLine.contains("claude"))
    #expect(HookHost.openclaw.robotSkipLine.contains("openclaw"))
    #expect(HookHost.hermes.robotSkipLine.contains("hermes"))
    #expect(HookHost.codex.robotSkipLine.contains("codex"))
    #expect(HookHost.cursor.robotSkipLine.contains("cursor"))
    #expect(HookHost.antigravity.robotSkipLine.contains("antigravity"))
    #expect(HookHost.antigravity.displayName == "Antigravity")
}

@Test func setupSlotSnapshot_hostless_usesHostlessCloserLines() {
    let slots = SetupSlotSnapshot(grok: .skipped, pi: .skipped, openCode: .skipped, wrote: [])
    #expect(slots.closer == .hostless)
    #expect(slots.slotViews.map(\.kind) == [.skipped, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped])
    #expect(slots.closer.lines(kind: .setup) == [setupCeremonyHostlessTitle, setupCeremonyHostlessNext])
    #expect(setupCeremonyFrames(slots, kind: .setup)?.last?.closerLines == slots.closer.lines(kind: .setup))
}

@Test func setupSlotSnapshot_wiredGrok_completeCloserAndReloadClause() {
    let slots = SetupSlotSnapshot(grok: .wired, pi: .skipped, openCode: .skipped, wrote: [.grok])
    #expect(slots.closer == .complete(skipped: []))
    #expect(slots.slotViews[0] == SetupSlotView(host: .grok, kind: .wired, clause: setupGrokReloadClause))
    #expect(slots.closer.lines(kind: .setup) == [setupCeremonyHooksWired])
    #expect(slots.closer.lines(kind: .install) == [setupCeremonyInstallCloser])
    #expect(setupCeremonyFrames(slots, kind: .setup)?.last?.closerLines == slots.closer.lines(kind: .setup))
    #expect(setupCeremonyFrames(slots, kind: .install)?.last?.closerLines == slots.closer.lines(kind: .install))
}

@Test func setupSlotSnapshot_occupiedOnly_neverComplete() {
    let slots = SetupSlotSnapshot(grok: .occupied, pi: .skipped, openCode: .skipped, wrote: [])
    #expect(slots.isQuiet == false)
    #expect(slots.closer == .skipped(skipped: [.grok]))
    #expect(slots.slotViews[0].clause == setupOccupiedClause)
    #expect(slots.closer.lines(kind: .setup) == [setupCeremonyHostlessTitle, setupCeremonyHostlessNext])
    #expect(setupCeremonyFrames(slots, kind: .setup)?.last?.closerLines == slots.closer.lines(kind: .setup))
}

@Test func setupSlotSnapshot_wiredWithSkips_carriesSkipsIntoCloser() {
    let slots = SetupSlotSnapshot(grok: .occupied, pi: .wired, openCode: .skipped, wrote: [.pi])
    #expect(slots.isQuiet == false)
    #expect(slots.closer == .complete(skipped: [.grok]))
    #expect(slots.closer.lines(kind: .setup) == [setupCeremonyHooksWired])
    #expect(setupCeremonyFrames(slots, kind: .setup)?.last?.closerLines == slots.closer.lines(kind: .setup))
}

@Test func setupSlotSnapshot_quietRun_closerIsQuiet() {
    let slots = SetupSlotSnapshot(grok: .wired, pi: .skipped, openCode: .skipped, wrote: [])
    #expect(slots.closer == .quiet)
    #expect(slots.closer.lines(kind: .setup) == [])
}

@Test func setupSlotSnapshot_secondMatchingRun_isQuiet() {
    let slots = SetupSlotSnapshot(grok: .wired, pi: .skipped, openCode: .skipped, wrote: [])
    #expect(slots.isQuiet)
    #expect(setupCeremonyFrames(slots, kind: .setup) == nil)
}

@Test func setupSlotSnapshot_quietAndCloserAreOneRule() {
    let quiet = SetupSlotSnapshot(grok: .wired, pi: .skipped, openCode: .skipped, wrote: [])
    #expect(quiet.isQuiet)
    #expect(setupCeremonyFrames(quiet, kind: .setup) == nil)

    let occupied = SetupSlotSnapshot(grok: .occupied, pi: .skipped, openCode: .skipped, wrote: [])
    #expect(occupied.isQuiet == false)
    #expect(occupied.closer == .skipped(skipped: [.grok]))

    let wired = SetupSlotSnapshot(grok: .wired, pi: .skipped, openCode: .skipped, wrote: [.grok])
    #expect(wired.isQuiet == false)
    #expect(wired.closer == .complete(skipped: []))
    #expect(wired.hasWiredSlot)
}
