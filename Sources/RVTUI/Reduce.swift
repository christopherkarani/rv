public func reduce(_ state: BrowseState, _ event: BrowseEvent) -> BrowseState {
    var next = state
    switch event {
    case .noop, .enter:
        return state
    case .quit:
        next.quit = true
        return next
    case .up:
        if next.selected > 0 {
            next.selected -= 1
        }
        return next
    case .down:
        if next.count > 0, next.selected < next.count - 1 {
            next.selected += 1
        }
        return next
    }
}
