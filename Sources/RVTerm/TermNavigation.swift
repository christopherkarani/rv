/// A key that moves between views. Keys that act inside a view (move,
/// allow, deny) belong to that view, not here.
public enum TermNavigationKey: Equatable, Sendable {
    /// `1`...`3`.
    case digit(Int)
    /// Space: Glance and Stream swap.
    case space
    /// Esc: back the way you came.
    case escape
    /// Tab and Shift-Tab: next and previous view.
    case tab
    case backTab
}

/// Which view is showing and how you got there. Esc walks the history
/// back; with no history it goes home to Glance.
public struct TermNavigation: Equatable, Sendable {
    public static let historyLimit = 20

    public private(set) var current: TermView
    public private(set) var history: [TermView]

    public init(start: TermView = .glance) {
        current = start
        history = []
    }

    /// Opens `view`, remembering where you were. Opening the view you are
    /// on changes nothing.
    public mutating func open(_ view: TermView) {
        guard view != current else { return }
        history.append(current)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        current = view
    }

    /// Esc. Returns false when there was nowhere to go (already home with
    /// no history), so the caller can treat Esc as "close" instead.
    @discardableResult
    public mutating func back() -> Bool {
        if let previous = history.popLast() {
            current = previous
            return true
        }
        guard current != .glance else { return false }
        current = .glance
        return true
    }

    /// Applies a navigation key. Returns whether it was handled.
    @discardableResult
    public mutating func handle(_ key: TermNavigationKey) -> Bool {
        switch key {
        case .digit(let number):
            guard let view = TermView(number: number) else { return false }
            open(view)
            return true
        case .space:
            open(current == .stream ? .glance : .stream)
            return true
        case .escape:
            return back()
        case .tab:
            open(Self.step(current, by: 1))
            return true
        case .backTab:
            open(Self.step(current, by: -1))
            return true
        }
    }

    static func step(_ view: TermView, by offset: Int) -> TermView {
        let all = TermView.allCases
        let index = all.firstIndex(of: view) ?? 0
        let count = all.count
        return all[((index + offset) % count + count) % count]
    }
}
