import Testing
@testable import RVPresentation

@Test func uninstallCeremony_alreadyClean_singleCloser() {
    let frames = uninstallCeremonyFrames(.alreadyClean(occupied: []))
    #expect(frames.count == 1)
    #expect(frames[0].closerLines == [uninstallCeremonyAlreadyClean])
    #expect(frames[0].slots.isEmpty)
}

@Test func uninstallCeremony_nonHostRemoval_completeWithoutSlots() {
    let frames = uninstallCeremonyFrames(.removed(hosts: [], occupied: []))
    #expect(frames.count == 1)
    #expect(frames[0].closerLines == [uninstallCeremonyCloser])
    #expect(frames[0].slots.isEmpty)
}

@Test func uninstallCeremony_removesHostsInOrder() {
    let frames = uninstallCeremonyFrames(
        .removed(hosts: [.grok, .openCode], occupied: [.pi])
    )
    #expect(frames.first?.title == uninstallCeremonyRemovingTitle)
    #expect(frames.first?.slots[0].kind == .wired)
    #expect(frames.first?.slots[1].kind == .occupied)
    #expect(frames.first?.slots[1].clause == uninstallOccupiedClause)
    #expect(frames.first?.slots[2].kind == .wired)

    let afterGrok = frames.first { frame in
        frame.slots[0].kind == .pending
            && frame.slots[2].kind == .wired
            && frame.title == uninstallCeremonyRemovingTitle
    }
    #expect(afterGrok != nil)

    #expect(frames.contains { $0.statusLine == uninstallCeremonyHooksRemoved })
    #expect(frames.last?.closerLines == [uninstallCeremonyCloser])
    #expect(frames.last?.slots.allSatisfy { $0.kind != .wired } == true)
}

@Test func uninstallCeremony_occupiedOnly_alreadyCleanNotComplete() {
    let frames = uninstallCeremonyFrames(
        .alreadyClean(occupied: [.grok])
    )
    #expect(frames.contains { $0.statusLine == uninstallCeremonyHooksRemoved } == false)
    #expect(frames.last?.closerLines == [uninstallCeremonyAlreadyClean])
    #expect(frames.last?.slots[0].kind == .occupied)
    #expect(frames.last?.slots[0].clause == uninstallOccupiedClause)
}
