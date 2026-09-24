import Foundation

public enum FocusDirection: String, Sendable, Equatable {
    case left
    case right
    case up
    case down
}

/// Cell rectangle of one pane's content, origin at the top left.
public struct PaneRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Int { x }
    public var maxX: Int { x + width }
    public var minY: Int { y }
    public var maxY: Int { y + height }
    public var midX: Int { x + width / 2 }
    public var midY: Int { y + height / 2 }
}

public enum PaneLayout {
    /// Assigns content rectangles. A split smaller than two cells keeps the first child.
    public static func frames(of tree: PaneTree, in bounds: PaneRect) -> [PaneID: PaneRect] {
        var frames: [PaneID: PaneRect] = [:]
        place(tree.shape, in: bounds, into: &frames)
        return frames
    }

    /// Nearest pane in `direction`, scored by edge gap then center distance.
    /// Ties break toward the top, then the left. Geometry, not creation order.
    public static func focus(
        from id: PaneID,
        direction: FocusDirection,
        frames: [PaneID: PaneRect]
    ) -> PaneID? {
        guard let origin = frames[id] else { return nil }
        var best: (PaneID, Int, Int, Int, Int, String)?
        for (candidate, rect) in frames where candidate != id {
            guard let score = separation(from: origin, to: rect, direction: direction) else { continue }
            let rank = (candidate, score.primary, score.secondary, rect.y, rect.x, candidate.rawValue.uuidString)
            if let current = best {
                if rank.1 < current.1
                    || (rank.1 == current.1 && rank.2 < current.2)
                    || (rank.1 == current.1 && rank.2 == current.2 && rank.3 < current.3)
                    || (rank.1 == current.1 && rank.2 == current.2 && rank.3 == current.3 && rank.4 < current.4)
                    || (rank.1 == current.1 && rank.2 == current.2 && rank.3 == current.3 && rank.4 == current.4 && rank.5 < current.5)
                {
                    best = rank
                }
            } else {
                best = rank
            }
        }
        return best?.0
    }

    private static func place(_ tree: PaneTree.Shape, in bounds: PaneRect, into frames: inout [PaneID: PaneRect]) {
        switch tree {
        case .empty:
            break
        case .leaf(let id):
            frames[id] = bounds
        case .split(let axis, let ratio, let first, let second):
            let (leading, trailing) = divide(bounds, axis: axis, ratio: ratio)
            place(first, in: leading, into: &frames)
            place(second, in: trailing, into: &frames)
        }
    }

    private static func divide(
        _ bounds: PaneRect,
        axis: SplitAxis,
        ratio: SplitRatio
    ) -> (PaneRect, PaneRect) {
        switch axis {
        case .vertical:
            let span = max(bounds.width, 1)
            var leading = span * ratio.firstBasisPoints / 10_000
            if span > 1 {
                leading = min(span - 1, max(1, leading))
            }
            return (
                PaneRect(x: bounds.x, y: bounds.y, width: leading, height: bounds.height),
                PaneRect(x: bounds.x + leading, y: bounds.y, width: span - leading, height: bounds.height)
            )
        case .horizontal:
            let span = max(bounds.height, 1)
            var leading = span * ratio.firstBasisPoints / 10_000
            if span > 1 {
                leading = min(span - 1, max(1, leading))
            }
            return (
                PaneRect(x: bounds.x, y: bounds.y, width: bounds.width, height: leading),
                PaneRect(x: bounds.x, y: bounds.y + leading, width: bounds.width, height: span - leading)
            )
        }
    }

    private static func separation(
        from origin: PaneRect,
        to candidate: PaneRect,
        direction: FocusDirection
    ) -> (primary: Int, secondary: Int)? {
        let primary: Int
        let secondary: Int
        switch direction {
        case .left:
            primary = origin.minX - candidate.maxX
            secondary = abs(origin.midY - candidate.midY)
        case .right:
            primary = candidate.minX - origin.maxX
            secondary = abs(origin.midY - candidate.midY)
        case .up:
            primary = origin.minY - candidate.maxY
            secondary = abs(origin.midX - candidate.midX)
        case .down:
            primary = candidate.minY - origin.maxY
            secondary = abs(origin.midX - candidate.midX)
        }
        guard primary >= 0 else { return nil }
        return (primary, secondary)
    }
}
