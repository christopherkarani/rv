/// Deterministic paced frames for `rv uninstall`. Reuses `SetupCeremonyFrame`.

public let uninstallCeremonyRemovingTitle = "Removing Hooks"
public let uninstallCeremonyHooksRemoved = "✓ Hooks removed"
public let uninstallCeremonyCloser = "Uninstall complete"
public let uninstallCeremonyAlreadyClean = "Already clean"
public let uninstallOccupiedClause = "left occupied"

public let uninstallCeremonyHostRemoveNs: UInt64 = 220_000_000
public let uninstallCeremonyPhaseGapNs: UInt64 = 280_000_000

public let uninstallRobotCompleteLine = "Uninstall complete."
public let uninstallRobotAlreadyCleanLine = "Already clean."

/// Closed taxonomy of terminal `rv uninstall` outcomes. Ceremony frames and
/// `--robot` lines both switch over it exhaustively.
public enum UninstallCloser: Equatable, Sendable {
    /// Deleted at least one owned artifact; payloads list the hosts deleted this run
    /// and the hosts left occupied.
    case removed(hosts: Set<SetupHostKind>, occupied: Set<SetupHostKind>)
    /// Deleted nothing; payload lists hosts left occupied.
    case alreadyClean(occupied: Set<SetupHostKind>)
}

/// Paced uninstall frames for `closer`. Never empty.
///
/// The closer is the robot contract too: pretty must not claim
/// `Uninstall complete` when nothing was deleted, and must not claim
/// `Already clean` when config / binaries / LaunchAgent were removed with no host slots.
public func uninstallCeremonyFrames(_ closer: UninstallCloser) -> [SetupCeremonyFrame] {
    switch closer {
    case .alreadyClean(let occupied):
        return [
            SetupCeremonyFrame(
                slots: occupiedSlots(occupied: occupied),
                closerLines: [uninstallCeremonyAlreadyClean],
                pauseNanoseconds: 0
            ),
        ]
    case .removed(let removed, let occupied):
        guard removed.isEmpty == false || occupied.isEmpty == false else {
            return [
                SetupCeremonyFrame(
                    closerLines: [uninstallCeremonyCloser],
                    pauseNanoseconds: 0
                ),
            ]
        }
        return removalAnimation(removed: removed, occupied: occupied)
    }
}

private func occupiedSlots(occupied: Set<SetupHostKind>) -> [SetupSlotView] {
    guard occupied.isEmpty == false else { return [] }
    return SetupHostKind.allCases.map { host in
        occupied.contains(host)
            ? SetupSlotView(host: host, kind: .occupied, clause: uninstallOccupiedClause)
            : SetupSlotView(host: host, kind: .pending)
    }
}

private func removalAnimation(
    removed: Set<SetupHostKind>,
    occupied: Set<SetupHostKind>
) -> [SetupCeremonyFrame] {
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
