public func mapKey(_ input: String) -> BrowseEvent {
    switch input {
    case "j", "\u{001B}[B", "\u{001B}OB":
        return .down
    case "k", "\u{001B}[A", "\u{001B}OA":
        return .up
    case "q", "Q", "\u{001B}":
        return .quit
    case "\r", "\n":
        return .enter
    default:
        return .noop
    }
}
