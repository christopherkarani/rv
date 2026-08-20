/// Whether the paced TTY show includes the theatrical download beat.
public enum SetupCeremonyKind: Equatable, Sendable {
    /// `install.sh` → `RV_FROM_INSTALL=1`. Download bar, then hosts, then install closer.
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

public let setupCeremonySearchActivity = "Searching for hosts…"
public let setupCeremonyWiringTitle = "Wiring Hooks"
public let setupCeremonyDownloadTitle = "Downloading"
public let setupCeremonyDownloadComplete = "✓ Download complete"
public let setupCeremonyAllHostsWired = "✓ All hosts wired"
public let setupCeremonyHooksWired = "Hooks wired"
public let setupCeremonyInstallCloser = "Install complete, run rv explain \"rm -rf\" to test"
public let setupCeremonyHostlessTitle = "No hosts yet"
public let setupCeremonyHostlessNext = "Next  rv setup"

public let setupCeremonyProgressTickNs: UInt64 = 80_000_000
public let setupCeremonyPhaseGapNs: UInt64 = 280_000_000
public let setupCeremonyHostWireNs: UInt64 = 220_000_000
public let setupCeremonySpinnerTickNs: UInt64 = 100_000_000

public let setupCeremonySpinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴"]

/// Deterministic paced frames from the final setup report. `nil` means quiet (no show).
public func setupCeremonyFrames(
    grok: SetupSlotKind,
    pi: SetupSlotKind,
    openCode: SetupSlotKind,
    wrote: Set<SetupHostKind>,
    kind: SetupCeremonyKind
) -> [SetupCeremonyFrame]? {
    func slotKind(_ host: SetupHostKind) -> SetupSlotKind {
        switch host {
        case .grok: grok
        case .pi: pi
        case .openCode: openCode
        }
    }
    let occupied = SetupHostKind.allCases.filter { slotKind($0) == .occupied }
    let detected = SetupHostKind.allCases.filter { slotKind($0) != .pending }
    if detected.isEmpty == false && wrote.isEmpty && occupied.isEmpty {
        return nil
    }

    let finalSlots = SetupHostKind.allCases.map { host in
        SetupSlotView(host: host, kind: slotKind(host), clause: setupSlotClause(host: host, kind: slotKind(host)))
    }
    let hasWired = finalSlots.contains { $0.kind == .wired }
    var frames: [SetupCeremonyFrame] = []

    if kind == .install {
        for step in 0...4 {
            let progress = Double(step) / 4.0
            frames.append(
                SetupCeremonyFrame(
                    title: setupCeremonyDownloadTitle,
                    progress: progress,
                    pauseNanoseconds: setupCeremonyProgressTickNs
                )
            )
        }
        frames.append(
            SetupCeremonyFrame(
                statusLine: setupCeremonyDownloadComplete,
                pauseNanoseconds: setupCeremonyPhaseGapNs
            )
        )
    }

    let emptySlots = SetupHostKind.allCases.map {
        SetupSlotView(host: $0, kind: .pending)
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
    for (index, host) in SetupHostKind.allCases.enumerated() {
        revealed[index] = finalSlots[index]
        frames.append(
            SetupCeremonyFrame(
                title: setupCeremonyWiringTitle,
                slots: revealed,
                pauseNanoseconds: setupCeremonyHostWireNs
            )
        )
        _ = host
    }

    if hasWired {
        switch kind {
        case .install:
            frames.append(
                SetupCeremonyFrame(
                    statusLine: setupCeremonyAllHostsWired,
                    slots: finalSlots,
                    pauseNanoseconds: setupCeremonyPhaseGapNs
                )
            )
            frames.append(
                SetupCeremonyFrame(
                    slots: finalSlots,
                    closerLines: [setupCeremonyInstallCloser],
                    pauseNanoseconds: 0
                )
            )
        case .setup:
            frames.append(
                SetupCeremonyFrame(
                    slots: finalSlots,
                    closerLines: [setupCeremonyHooksWired],
                    pauseNanoseconds: 0
                )
            )
        }
    } else {
        frames.append(
            SetupCeremonyFrame(
                slots: finalSlots,
                closerLines: [setupCeremonyHostlessTitle, setupCeremonyHostlessNext],
                pauseNanoseconds: 0
            )
        )
    }

    return frames
}

public func setupSlotClause(host: SetupHostKind, kind: SetupSlotKind) -> String? {
    switch kind {
    case .wired where host == .grok:
        return setupGrokReloadClause
    case .occupied:
        return setupOccupiedClause
    case .pending, .wired:
        return nil
    }
}
