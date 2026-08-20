/// Deterministic paced frames for `rv uninstall`. Reuses `SetupCeremonyFrame`.

public let uninstallCeremonyRemovingTitle = "Removing Hooks"
public let uninstallCeremonyHooksRemoved = "✓ Hooks removed"
public let uninstallCeremonyCloser = "Uninstall complete"
public let uninstallCeremonyAlreadyClean = "Already clean"
public let uninstallOccupiedClause = "left occupied"

public let uninstallCeremonyHostRemoveNs: UInt64 = 220_000_000
public let uninstallCeremonyPhaseGapNs: UInt64 = 280_000_000

/// Builds the uninstall show from which hosts were deleted vs left occupied.
public func uninstallCeremonyFrames(
    removed: Set<SetupHostKind>,
    occupied: Set<SetupHostKind>
) -> [SetupCeremonyFrame] {
    if removed.isEmpty && occupied.isEmpty {
        return [
            SetupCeremonyFrame(
                closerLines: [uninstallCeremonyAlreadyClean],
                pauseNanoseconds: 0
            ),
        ]
    }

    func slot(for host: SetupHostKind, stillPresent: Bool) -> SetupSlotView {
        if occupied.contains(host) {
            return SetupSlotView(host: host, kind: .occupied, clause: uninstallOccupiedClause)
        }
        if stillPresent && removed.contains(host) {
            return SetupSlotView(host: host, kind: .wired)
        }
        return SetupSlotView(host: host, kind: .pending)
    }

    var stillPresent = removed
    var frames: [SetupCeremonyFrame] = []

    let initial = SetupHostKind.allCases.map { slot(for: $0, stillPresent: stillPresent.contains($0)) }
    frames.append(
        SetupCeremonyFrame(
            title: uninstallCeremonyRemovingTitle,
            slots: initial,
            pauseNanoseconds: uninstallCeremonyHostRemoveNs
        )
    )

    for host in SetupHostKind.allCases where removed.contains(host) {
        stillPresent.remove(host)
        let slots = SetupHostKind.allCases.map { slot(for: $0, stillPresent: stillPresent.contains($0)) }
        frames.append(
            SetupCeremonyFrame(
                title: uninstallCeremonyRemovingTitle,
                slots: slots,
                pauseNanoseconds: uninstallCeremonyHostRemoveNs
            )
        )
    }

    let finalSlots = SetupHostKind.allCases.map { slot(for: $0, stillPresent: false) }
    if removed.isEmpty == false {
        frames.append(
            SetupCeremonyFrame(
                statusLine: uninstallCeremonyHooksRemoved,
                slots: finalSlots,
                pauseNanoseconds: uninstallCeremonyPhaseGapNs
            )
        )
    }

    frames.append(
        SetupCeremonyFrame(
            statusLine: removed.isEmpty ? nil : uninstallCeremonyHooksRemoved,
            slots: finalSlots,
            closerLines: [uninstallCeremonyCloser],
            pauseNanoseconds: 0
        )
    )
    return frames
}
