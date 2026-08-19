import Testing
@testable import RVPresentation

@Test func setupViewModel_hostless_paintsHostlessCloser() {
    let show = setupViewModel(grok: .pending, pi: .pending, openCode: .pending, wrote: [])
    guard case .painted(let model) = show else {
        Issue.record("expected painted hostless show")
        return
    }
    #expect(model.slots.map(\.kind) == [.pending, .pending, .pending])
    #expect(model.activity == setupLookingActivity)
    #expect(model.closer == .hostless)
    #expect(model.closer.title == "No hosts yet")
    #expect(model.closer.next == "Next  rv setup")
}

@Test func setupViewModel_wiredGrok_completeCloserAndReloadClause() {
    let show = setupViewModel(grok: .wired, pi: .pending, openCode: .pending, wrote: [.grok])
    guard case .painted(let model) = show else {
        Issue.record("expected painted wired show")
        return
    }
    #expect(model.slots[0] == SetupSlotView(host: .grok, kind: .wired, clause: setupGrokReloadClause))
    #expect(model.activity == "wiring Grok")
    #expect(model.closer == .complete)
    #expect(model.closer.next.contains("rv test"))
}

@Test func setupViewModel_occupiedOnly_neverComplete() {
    let show = setupViewModel(grok: .occupied, pi: .pending, openCode: .pending, wrote: [])
    guard case .painted(let model) = show else {
        Issue.record("expected painted occupied-only show")
        return
    }
    #expect(model.slots[0].clause == setupOccupiedClause)
    #expect(model.closer == .hostless)
}

@Test func setupViewModel_secondMatchingRun_isQuiet() {
    let show = setupViewModel(grok: .wired, pi: .pending, openCode: .pending, wrote: [])
    #expect(show == .quiet)
}
