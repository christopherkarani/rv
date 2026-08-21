import Testing
@testable import RVPresentation

@Test func setupSlotSnapshot_hostless_usesHostlessCloserLines() {
    let slots = SetupSlotSnapshot(grok: .pending, pi: .pending, openCode: .pending, wrote: [])
    #expect(slots.closer == .hostless)
    #expect(slots.slotViews.map(\.kind) == [.pending, .pending, .pending])
    #expect(slots.closer.lines(kind: .setup) == [setupCeremonyHostlessTitle, setupCeremonyHostlessNext])
    #expect(setupCeremonyFrames(slots, kind: .setup)?.last?.closerLines == slots.closer.lines(kind: .setup))
}

@Test func setupSlotSnapshot_wiredGrok_completeCloserAndReloadClause() {
    let slots = SetupSlotSnapshot(grok: .wired, pi: .pending, openCode: .pending, wrote: [.grok])
    #expect(slots.closer == .complete)
    #expect(slots.slotViews[0] == SetupSlotView(host: .grok, kind: .wired, clause: setupGrokReloadClause))
    #expect(slots.closer.lines(kind: .setup) == [setupCeremonyHooksWired])
    #expect(slots.closer.lines(kind: .install) == [setupCeremonyInstallCloser])
    #expect(setupCeremonyFrames(slots, kind: .setup)?.last?.closerLines == slots.closer.lines(kind: .setup))
    #expect(setupCeremonyFrames(slots, kind: .install)?.last?.closerLines == slots.closer.lines(kind: .install))
}

@Test func setupSlotSnapshot_occupiedOnly_neverComplete() {
    let slots = SetupSlotSnapshot(grok: .occupied, pi: .pending, openCode: .pending, wrote: [])
    #expect(slots.isQuiet == false)
    #expect(slots.closer == .hostless)
    #expect(slots.slotViews[0].clause == setupOccupiedClause)
    #expect(setupCeremonyFrames(slots, kind: .setup)?.last?.closerLines == slots.closer.lines(kind: .setup))
}

@Test func setupSlotSnapshot_secondMatchingRun_isQuiet() {
    let slots = SetupSlotSnapshot(grok: .wired, pi: .pending, openCode: .pending, wrote: [])
    #expect(slots.isQuiet)
    #expect(setupCeremonyFrames(slots, kind: .setup) == nil)
}

@Test func setupSlotSnapshot_quietAndCloserAreOneRule() {
    let quiet = SetupSlotSnapshot(grok: .wired, pi: .pending, openCode: .pending, wrote: [])
    #expect(quiet.isQuiet)
    #expect(setupCeremonyFrames(quiet, kind: .setup) == nil)

    let occupied = SetupSlotSnapshot(grok: .occupied, pi: .pending, openCode: .pending, wrote: [])
    #expect(occupied.isQuiet == false)
    #expect(occupied.closer == .hostless)

    let wired = SetupSlotSnapshot(grok: .wired, pi: .pending, openCode: .pending, wrote: [.grok])
    #expect(wired.isQuiet == false)
    #expect(wired.closer == .complete)
    #expect(wired.hasWiredSlot)
}
