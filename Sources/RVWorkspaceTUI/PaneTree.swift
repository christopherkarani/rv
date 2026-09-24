import Foundation

/// How a split divides its parent rectangle. The ratio is retained so a later
/// chunk can resize panes without changing the tree shape.
public enum SplitAxis: String, Sendable, Equatable, Codable {
    /// Side by side. The first child is on the left.
    case vertical
    /// Stacked. The first child is on top.
    case horizontal
}

/// Share of the parent given to the first child, in basis points (0...10_000).
public struct SplitRatio: Sendable, Equatable, Codable {
    public let firstBasisPoints: Int

    public static let even = SplitRatio(firstBasisPoints: 5_000)

    public init(firstBasisPoints: Int) {
        self.firstBasisPoints = min(10_000, max(0, firstBasisPoints))
    }
}

public enum PaneTreeError: Error, Equatable, Sendable {
    case missingPane
    case duplicatePane
}

/// A recursive pane layout whose constructors preserve its structural invariants.
///
/// The root may be empty, a leaf appears once, and every split has two nonempty
/// children. `PaneTree.Shape` is an inspection snapshot; callers cannot use it
/// to construct or mutate a tree.
public struct PaneTree: Equatable, Sendable {
    private indirect enum Node: Equatable, Sendable {
        case empty
        case leaf(PaneID)
        case split(axis: SplitAxis, ratio: SplitRatio, first: Node, second: Node)
    }

    public indirect enum Shape: Equatable, Sendable {
        case empty
        case leaf(PaneID)
        case split(axis: SplitAxis, ratio: SplitRatio, first: Shape, second: Shape)
    }

    private let node: Node

    private init(_ node: Node) {
        self.node = node
    }

    public static let empty = PaneTree(.empty)

    public static func leaf(_ pane: PaneID) -> PaneTree {
        PaneTree(.leaf(pane))
    }

    public var shape: Shape {
        switch node {
        case .empty:
            .empty
        case .leaf(let pane):
            .leaf(pane)
        case .split(let axis, let ratio, let first, let second):
            .split(axis: axis, ratio: ratio, first: PaneTree(first).shape, second: PaneTree(second).shape)
        }
    }

    public var isEmpty: Bool {
        if case .empty = node { return true }
        return false
    }

    public var paneIDs: [PaneID] {
        switch node {
        case .empty:
            []
        case .leaf(let id):
            [id]
        case .split(_, _, let first, let second):
            PaneTree(first).paneIDs + PaneTree(second).paneIDs
        }
    }

    public var isUniquelyIdentified: Bool {
        Set(paneIDs).count == paneIDs.count
    }

    public func contains(_ id: PaneID) -> Bool {
        paneIDs.contains(id)
    }

    public var firstLeaf: PaneID? {
        Self.firstLeaf(in: node)
    }

    /// Replaces `target` with a split. The previous leaf stays first. `inserted` becomes second.
    /// Failure leaves the caller holding the original tree.
    public func splitting(
        _ target: PaneID,
        axis: SplitAxis,
        ratio: SplitRatio = .even,
        inserted: PaneID
    ) -> Result<PaneTree, PaneTreeError> {
        guard contains(target) else { return .failure(.missingPane) }
        guard contains(inserted) == false else { return .failure(.duplicatePane) }
        return .success(PaneTree(Self.replacing(node, target: target, axis: axis, ratio: ratio, inserted: inserted)))
    }

    /// Removes a leaf and collapses its parent. Focus moves to the nearest
    /// surviving sibling leaf, preferring the first leaf in that subtree.
    public func closing(_ id: PaneID) -> Result<(tree: PaneTree, focus: PaneID?), PaneTreeError> {
        let (next, removed, focus) = Self.removing(node, target: id)
        guard removed else { return .failure(.missingPane) }
        return .success((PaneTree(next), focus ?? Self.firstLeaf(in: next)))
    }

    /// Builds a deterministic, axis-alternating balanced tree in caller order.
    public static func balanced(
        _ ids: [PaneID],
        axis: SplitAxis = .vertical
    ) -> Result<PaneTree, PaneTreeError> {
        guard Set(ids).count == ids.count else { return .failure(.duplicatePane) }
        return .success(PaneTree(balancedNode(ids, axis: axis)))
    }

    private static func replacing(
        _ node: Node,
        target: PaneID,
        axis: SplitAxis,
        ratio: SplitRatio,
        inserted: PaneID
    ) -> Node {
        switch node {
        case .empty:
            return node
        case .leaf(let id):
            guard id == target else { return node }
            return .split(axis: axis, ratio: ratio, first: node, second: .leaf(inserted))
        case .split(let currentAxis, let currentRatio, let first, let second):
            return .split(
                axis: currentAxis,
                ratio: currentRatio,
                first: replacing(first, target: target, axis: axis, ratio: ratio, inserted: inserted),
                second: replacing(second, target: target, axis: axis, ratio: ratio, inserted: inserted)
            )
        }
    }

    private static func removing(_ node: Node, target: PaneID) -> (Node, Bool, PaneID?) {
        switch node {
        case .empty:
            return (.empty, false, nil)
        case .leaf(let id):
            return id == target ? (.empty, true, nil) : (node, false, nil)
        case .split(let axis, let ratio, let first, let second):
            let (nextFirst, removedFirst, firstFocus) = removing(first, target: target)
            if removedFirst {
                if case .empty = nextFirst {
                    return (second, true, firstLeaf(in: second))
                }
                return (.split(axis: axis, ratio: ratio, first: nextFirst, second: second), true, firstFocus)
            }

            let (nextSecond, removedSecond, secondFocus) = removing(second, target: target)
            guard removedSecond else { return (node, false, nil) }
            if case .empty = nextSecond {
                return (first, true, firstLeaf(in: first))
            }
            return (.split(axis: axis, ratio: ratio, first: first, second: nextSecond), true, secondFocus)
        }
    }

    private static func firstLeaf(in node: Node) -> PaneID? {
        switch node {
        case .empty:
            nil
        case .leaf(let id):
            id
        case .split(_, _, let first, let second):
            firstLeaf(in: first) ?? firstLeaf(in: second)
        }
    }

    private static func balancedNode(_ ids: [PaneID], axis: SplitAxis) -> Node {
        guard let first = ids.first else { return .empty }
        guard ids.count > 1 else { return .leaf(first) }
        let midpoint = ids.count / 2
        let next: SplitAxis = axis == .vertical ? .horizontal : .vertical
        return .split(
            axis: axis,
            ratio: .even,
            first: balancedNode(Array(ids[..<midpoint]), axis: next),
            second: balancedNode(Array(ids[midpoint...]), axis: next)
        )
    }
}
