import RVDomain

/// Whether the paced TTY show uses the install closer (download UI lives in `install.sh`).
public enum SetupCeremonyKind: Equatable, Sendable {
    /// `install.sh` → `RV_FROM_INSTALL=1`. Hosts, then install closer.
    /// Real download progress is painted by `install.sh` before `exec rv setup`.
    case install
    /// Plain `rv setup`. Search + wire only.
    case setup
}

/// One redraw of the paced setup / install show.
public struct SetupCeremonyFrame: Equatable, Sendable {
    public var title: String?
    public var progress: Double?
    public var spinnerIndex: Int?
    public var activity: String?
    public var statusLine: String?
    public var slots: [SetupSlotView]
    public var closerLines: [String]
    /// Suggested pause after painting this frame (player may zero this).
    public var pauseNanoseconds: UInt64

    public init(
        title: String? = nil,
        progress: Double? = nil,
        spinnerIndex: Int? = nil,
        activity: String? = nil,
        statusLine: String? = nil,
        slots: [SetupSlotView] = [],
        closerLines: [String] = [],
        pauseNanoseconds: UInt64 = 0
    ) {
        self.title = title
        self.progress = progress
        self.spinnerIndex = spinnerIndex
        self.activity = activity
        self.statusLine = statusLine
        self.slots = slots
        self.closerLines = closerLines
        self.pauseNanoseconds = pauseNanoseconds
    }
}

package let setupCeremonySearchActivity = "Searching for hosts…"
package let setupCeremonyWiringTitle = "Wiring Hooks"
package let setupCeremonyDownloadTitle = "Downloading"
package let setupCeremonyDownloadComplete = "✓ Download complete"
package let setupCeremonyAllHostsWired = "✓ All hosts wired"
package let setupCeremonyHooksWired = "Hooks wired"
package let setupCeremonyInstallCloser = "Install complete, run rv explain \"rm -rf\" to test"
package let setupCeremonyHostlessTitle = "No hosts yet"
package let setupCeremonyHostlessNext = "Next  rv setup"

package let setupCeremonyProgressTickNs: UInt64 = 80_000_000
package let setupCeremonyPhaseGapNs: UInt64 = 280_000_000
package let setupCeremonyHostWireNs: UInt64 = 220_000_000
package let setupCeremonySpinnerTickNs: UInt64 = 100_000_000

public let setupCeremonySpinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴"]

/// Deterministic paced frames from the final setup report. `nil` means quiet (no show).
public func setupCeremonyFrames(
    grok: SetupSlotKind,
    pi: SetupSlotKind,
    openCode: SetupSlotKind,
    claude: SetupSlotKind = .skipped,
    openClaw: SetupSlotKind = .skipped,
    hermes: SetupSlotKind = .skipped,
    codex: SetupSlotKind = .skipped,
    cursor: SetupSlotKind = .skipped,
    wrote: Set<HookHost>,
    kind: SetupCeremonyKind
) -> [SetupCeremonyFrame]? {
    setupCeremonyFrames(
        SetupSlotSnapshot(
            grok: grok,
            pi: pi,
            openCode: openCode,
            claude: claude,
            openClaw: openClaw,
            hermes: hermes,
            codex: codex,
            cursor: cursor,
            wrote: wrote
        ),
        kind: kind
    )
}

public func setupCeremonyFrames(
    _ slots: SetupSlotSnapshot,
    kind: SetupCeremonyKind
) -> [SetupCeremonyFrame]? {
    if slots.closer == .quiet {
        return nil
    }

    let finalSlots = slots.slotViews
    var frames: [SetupCeremonyFrame] = []

    let emptySlots = HookHost.setupSlotOrder.map {
        SetupSlotView(host: $0, kind: .skipped)
    }
    for spin in 0..<setupCeremonySpinnerFrames.count {
        frames.append(
            SetupCeremonyFrame(
                spinnerIndex: spin,
                activity: setupCeremonySearchActivity,
                slots: emptySlots,
                pauseNanoseconds: setupCeremonySpinnerTickNs
            )
        )
    }
    frames.append(
        SetupCeremonyFrame(
            activity: setupCeremonySearchActivity,
            slots: emptySlots,
            pauseNanoseconds: setupCeremonyPhaseGapNs
        )
    )

    var revealed = emptySlots
    frames.append(
        SetupCeremonyFrame(
            title: setupCeremonyWiringTitle,
            slots: revealed,
            pauseNanoseconds: setupCeremonyHostWireNs
        )
    )
    for index in HookHost.setupSlotOrder.indices {
        revealed[index] = finalSlots[index]
        frames.append(
            SetupCeremonyFrame(
                title: setupCeremonyWiringTitle,
                slots: revealed,
                pauseNanoseconds: setupCeremonyHostWireNs
            )
        )
    }

    if case .complete = slots.closer, kind == .install {
        frames.append(
            SetupCeremonyFrame(
                statusLine: setupCeremonyAllHostsWired,
                slots: finalSlots,
                pauseNanoseconds: setupCeremonyPhaseGapNs
            )
        )
    }
    frames.append(
        SetupCeremonyFrame(
            slots: finalSlots,
            closerLines: slots.closer.lines(kind: kind),
            pauseNanoseconds: 0
        )
    )

    return frames
}

package func setupSlotClause(host: HookHost, kind: SetupSlotKind) -> String? {
    switch kind {
    case .wired where host == .grok:
        return setupGrokReloadClause
    case .wired where host == .codex:
        return setupCodexTrustClause
    case .occupied:
        return setupOccupiedClause
    case .skipped, .wired:
        return nil
    }
}
