import RVTheme

func browseFrame(_ state: BrowseState, palette: Palette) -> [String] {
    if state.rows.isEmpty {
        return [paint("(empty)", slot: palette.muted, reset: palette.reset)]
    }
    let start = state.page * state.pageSize
    let end = min(state.rows.count, start + state.pageSize)
    guard start < end else { return [] }
    return (start..<end).map { index in
        let marker = index == state.selected ? ">" : " "
        let line = "\(marker) \(state.rows[index])"
        if index == state.selected {
            return paint(line, slot: palette.fact, reset: palette.reset)
        }
        return line
    }
}

public func render(_ state: BrowseState, palette: Palette) -> [String] {
    browseFrame(state, palette: palette)
}
