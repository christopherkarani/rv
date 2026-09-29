import Testing
@testable import RVPresentation

@Test func setupSlotClause_skippedAndWired_produceNoOccupiedClause() {
    #expect(setupSlotClause(host: .pi, kind: .skipped) == nil)
    #expect(setupSlotClause(host: .pi, kind: .wired) == nil)
    #expect(setupSlotClause(host: .grok, kind: .skipped) == nil)
    #expect(setupSlotClause(host: .codex, kind: .skipped) == nil)
    #expect(setupSlotClause(host: .pi, kind: .occupied) == setupOccupiedClause)
}

@Test func setupCeremony_quietSecondRun_returnsNil() {
    let frames = setupCeremonyFrames(
        grok: .wired,
        pi: .skipped,
        openCode: .skipped,
        wrote: [],
        kind: .setup
    )
    #expect(frames == nil)
}

@Test func setupCeremony_setup_wiredEndsWithHooksWired() {
    let frames = setupCeremonyFrames(
        grok: .wired,
        pi: .skipped,
        openCode: .skipped,
        wrote: [.grok],
        kind: .setup
    )
    guard let frames else {
        Issue.record("expected frames")
        return
    }
    #expect(frames.contains { $0.progress != nil } == false)
    #expect(frames.contains { $0.activity == setupCeremonySearchActivity })
    #expect(frames.contains { $0.title == setupCeremonyWiringTitle })
    #expect(frames.last?.closerLines == [setupCeremonyHooksWired])
    #expect(frames.last?.slots[0].kind == .wired)
}

@Test func setupCeremony_install_skipsDownloadUsesExplainCloser() {
    let frames = setupCeremonyFrames(
        grok: .wired,
        pi: .wired,
        openCode: .skipped,
        wrote: [.grok, .pi],
        kind: .install
    )
    guard let frames else {
        Issue.record("expected frames")
        return
    }
    // Download bar is owned by install.sh (real bytes); ceremony starts at search.
    #expect(frames.contains { $0.progress != nil } == false)
    #expect(frames.contains { $0.title == setupCeremonyDownloadTitle } == false)
    #expect(frames.contains { $0.statusLine == setupCeremonyDownloadComplete } == false)
    #expect(frames.contains { $0.statusLine == setupCeremonyAllHostsWired })
    #expect(frames.last?.closerLines == [setupCeremonyInstallCloser])
}

@Test func setupCeremony_hostless_install_skipsWiredClaims() {
    let frames = setupCeremonyFrames(
        grok: .skipped,
        pi: .skipped,
        openCode: .skipped,
        wrote: [],
        kind: .install
    )
    guard let frames else {
        Issue.record("expected frames")
        return
    }
    #expect(frames.contains { $0.statusLine == setupCeremonyAllHostsWired } == false)
    #expect(frames.last?.closerLines == [setupCeremonyHostlessTitle, setupCeremonyHostlessNext])
}

@Test func setupCeremony_wiringRevealsHostsInOrder() {
    let frames = setupCeremonyFrames(
        grok: .wired,
        pi: .occupied,
        openCode: .wired,
        wrote: [.grok, .opencode],
        kind: .setup
    )
    guard let frames else {
        Issue.record("expected frames")
        return
    }
    let wiring = frames.filter { $0.title == setupCeremonyWiringTitle }
    #expect(wiring.count >= 8)
    #expect(wiring[0].slots.map(\.kind) == [.skipped, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped])
    #expect(wiring[1].slots.map(\.kind) == [.wired, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped])
    #expect(wiring[2].slots.map(\.kind) == [.wired, .occupied, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped])
    #expect(wiring[3].slots.map(\.kind) == [.wired, .occupied, .wired, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped])
    #expect(wiring[4].slots.map(\.kind) == [.wired, .occupied, .wired, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped])
    #expect(wiring[5].slots.map(\.kind) == [.wired, .occupied, .wired, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped])
    #expect(wiring[6].slots.map(\.kind) == [.wired, .occupied, .wired, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped])
    #expect(wiring[7].slots.map(\.kind) == [.wired, .occupied, .wired, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped])
}
