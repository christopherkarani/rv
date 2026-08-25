import RVPresentation
import RVTheme

public struct ScanBrowseState: Equatable, Sendable {
    public var model: ScanViewModel
    public var selectedIndex: Int

    public init(model: ScanViewModel, selectedIndex: Int = 0) {
        self.model = model
        self.selectedIndex = Self.clampedSelection(selectedIndex, rowCount: model.rows.count)
    }

    fileprivate static func clampedSelection(_ selectedIndex: Int, rowCount: Int) -> Int {
        guard rowCount > 0 else { return 0 }
        return min(max(0, selectedIndex), rowCount - 1)
    }
}

public enum ScanBrowseEvent: Equatable, Sendable {
    case up
    case down
    case enter
    case quit
    case noop
}

public func scanBrowseState(
    model: ScanViewModel,
    selectedIndex: Int = 0
) -> ScanBrowseState {
    ScanBrowseState(model: model, selectedIndex: selectedIndex)
}

public func scanBrowseReduce(_ state: ScanBrowseState, _ event: ScanBrowseEvent) -> ScanBrowseState {
    var next = state
    switch event {
    case .up:
        guard next.model.rows.isEmpty == false else { break }
        next.selectedIndex = max(0, next.selectedIndex - 1)
    case .down:
        guard next.model.rows.isEmpty == false else { break }
        next.selectedIndex = min(next.model.rows.count - 1, next.selectedIndex + 1)
    case .enter, .quit, .noop:
        break
    }
    next.selectedIndex = ScanBrowseState.clampedSelection(next.selectedIndex, rowCount: next.model.rows.count)
    return next
}

public func scanBrowseRender(_ state: ScanBrowseState, palette: Palette) -> [String] {
    let selectedIndex = ScanBrowseState.clampedSelection(state.selectedIndex, rowCount: state.model.rows.count)
    var lines: [String] = [paint("RV SCAN", slot: palette.silver, reset: palette.reset), ""]
    if state.model.rows.isEmpty {
        lines.append(paint("No deny findings.", slot: palette.muted, reset: palette.reset))
    } else {
        for (index, row) in state.model.rows.enumerated() {
            lines.append(browseListLine(row, selected: index == selectedIndex, palette: palette))
        }
        lines.append("")
        lines.append(contentsOf: browseDetail(state.model.rows[selectedIndex], palette: palette))
    }
    for warning in state.model.warnings {
        lines.append(
            paint("warning \(warning.code): \(warning.message)", slot: palette.mark, reset: palette.reset)
        )
    }
    lines.append("")
    lines.append(summaryBrowseLine(state.model, palette: palette))
    if state.model.setupNudgeRecommended {
        lines.append(
            paint(
                "Some hosts are not wired. Run rv setup or rv doctor.",
                slot: palette.silver,
                reset: palette.reset
            )
        )
    }
    lines.append("")
    lines.append(paint("j/k move · q quit", slot: palette.muted, reset: palette.reset))
    return lines
}

private func browseListLine(_ row: ScanFindingRow, selected: Bool, palette: Palette) -> String {
    let marker = selected ? paint("›", slot: palette.mark, reset: palette.reset) : " "
    let rule = paint(row.ruleLabel, slot: selected ? palette.deny : palette.fact, reset: palette.reset)
    let command = paint(row.commandDisplay, slot: palette.fact, reset: palette.reset)
    let countSuffix = row.count > 1 ? paint(" ×\(row.count)", slot: palette.muted, reset: palette.reset) : ""
    return "\(marker) \(rule)  \(command)\(countSuffix)"
}

private func browseDetail(_ row: ScanFindingRow, palette: Palette) -> [String] {
    var children: [OutlineItem] = [
        .leaf(label: "Host", value: row.host.rawValue, emphasis: .fact),
        .leaf(label: "Pack", value: row.packID.rawValue, emphasis: .plain),
        .leaf(label: "Rule", value: row.ruleLabel, emphasis: .deny),
        .leaf(label: "Command", value: row.commandDisplay, emphasis: .fact),
        .leaf(label: "Path", value: row.sourcePath, emphasis: .muted),
    ]
    if let sessionID = row.sessionID {
        children.append(.leaf(label: "Session", value: sessionID, emphasis: .plain))
    }
    if row.count > 1 {
        children.append(.leaf(label: "Count", value: String(row.count), emphasis: .plain))
    }
    return renderTree(root: "Finding", emphasis: .heading, children: children, palette: palette)
}

private func summaryBrowseLine(_ model: ScanViewModel, palette: Palette) -> String {
    let findingWord = model.rows.count == 1 ? "finding" : "findings"
    let text =
        "\(model.filesScanned) files scanned, \(model.eventsExtracted) events, \(model.rows.count) \(findingWord)"
    return paint(text, slot: palette.muted, reset: palette.reset)
}
