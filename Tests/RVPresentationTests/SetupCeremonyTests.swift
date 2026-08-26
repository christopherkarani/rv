import Testing
@testable import RVPresentation

@Test func setupCeremony_quietSecondRun_returnsNil() {
    let frames = setupCeremonyFrames(
        grok: .wired,
        pi: .pending,
        openCode: .pending,
        wrote: [],
        kind: .setup
    )
    #expect(frames == nil)
}

@Test func setupCeremony_setup_wiredEndsWithHooksWired() {
    let frames = setupCeremonyFrames(
        grok: .wired,
        pi: .pending,
        openCode: .pending,
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

@Test func setupCeremony_install_includesDownloadAndExplainCloser() {
    let frames = setupCeremonyFrames(
        grok: .wired,
        pi: .wired,
        openCode: .pending,
        wrote: [.grok, .pi],
        kind: .install
    )
    guard let frames else {
        Issue.record("expected frames")
        return
    }
    #expect(frames.contains { $0.progress == 0 })
    #expect(frames.contains { $0.progress == 1 })
    #expect(frames.contains { $0.statusLine == setupCeremonyDownloadComplete })
    #expect(frames.contains { $0.statusLine == setupCeremonyAllHostsWired })
    #expect(frames.last?.closerLines == [setupCeremonyInstallCloser])
}

@Test func setupCeremony_hostless_install_skipsWiredClaims() {
    let frames = setupCeremonyFrames(
        grok: .pending,
        pi: .pending,
        openCode: .pending,
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
    #expect(wiring.count >= 6)
    #expect(wiring[0].slots.map(\.kind) == [.pending, .pending, .pending, .pending, .pending])
    #expect(wiring[1].slots.map(\.kind) == [.wired, .pending, .pending, .pending, .pending])
    #expect(wiring[2].slots.map(\.kind) == [.wired, .occupied, .pending, .pending, .pending])
    #expect(wiring[3].slots.map(\.kind) == [.wired, .occupied, .wired, .pending, .pending])
    #expect(wiring[4].slots.map(\.kind) == [.wired, .occupied, .wired, .pending, .pending])
    #expect(wiring[5].slots.map(\.kind) == [.wired, .occupied, .wired, .pending, .pending])
}
