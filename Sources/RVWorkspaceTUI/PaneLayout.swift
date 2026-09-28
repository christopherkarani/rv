import Foundation

public struct PaneID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct TabID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct SplitID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct ViewID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// A vertical divider puts children left/right; a horizontal divider puts them top/bottom.
public enum SplitAxis: String, Codable, Sendable {
    case vertical
    case horizontal
}

/// Fixed point ratios keep saved layouts and integer cell rounding deterministic.
public struct SplitRatio: Equatable, Codable, Sendable {
    public let thousandths: Int
    public static let half = SplitRatio(thousandths: 500)

    public init(thousandths: Int) {
        self.thousandths = min(999, max(1, thousandths))
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(Int.self)
        guard (1...999).contains(value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "split ratio must be between 1 and 999 thousandths"
            )
        }
        thousandths = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(thousandths)
    }
}

public indirect enum PaneTree: Equatable, Codable, Sendable {
    case leaf(PaneID)
    case split(SplitID, SplitAxis, SplitRatio, PaneTree, PaneTree)

    public static let maximumLeaves = 8

    private enum CaseKey: String, CodingKey { case leaf, split }
    private enum ValueKey: String, CodingKey { case _0, _1, _2, _3, _4 }

    public init(from decoder: any Decoder) throws {
        var remainingNodes = 2 * Self.maximumLeaves - 1
        self = try Self.decode(from: decoder, depth: 0, remainingNodes: &remainingNodes)
    }

    private static func decode(
        from decoder: any Decoder,
        depth: Int,
        remainingNodes: inout Int
    ) throws -> PaneTree {
        guard depth < Self.maximumLeaves, remainingNodes > 0 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "pane tree exceeds the supported depth or node limit"
            ))
        }
        remainingNodes -= 1
        let container = try decoder.container(keyedBy: CaseKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "pane tree node must have exactly one case"
            ))
        }
        switch key {
        case .leaf:
            let leaf = try container.nestedContainer(keyedBy: ValueKey.self, forKey: .leaf)
            return .leaf(try leaf.decode(PaneID.self, forKey: ._0))
        case .split:
            let split = try container.nestedContainer(keyedBy: ValueKey.self, forKey: .split)
            let id = try split.decode(SplitID.self, forKey: ._0)
            let axis = try split.decode(SplitAxis.self, forKey: ._1)
            let ratio = try split.decode(SplitRatio.self, forKey: ._2)
            let first = try Self.decode(
                from: split.superDecoder(forKey: ._3), depth: depth + 1, remainingNodes: &remainingNodes
            )
            let second = try Self.decode(
                from: split.superDecoder(forKey: ._4), depth: depth + 1, remainingNodes: &remainingNodes
            )
            return .split(id, axis, ratio, first, second)
        }
    }

    public var leafIDs: [PaneID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, _, _, let first, let second): first.leafIDs + second.leafIDs
        }
    }

    public var leafCount: Int { leafIDs.count }

    public var splitIDs: [SplitID] {
        switch self {
        case .leaf: []
        case .split(let id, _, _, let first, let second): [id] + first.splitIDs + second.splitIDs
        }
    }

    public var minimumOuterSize: CellSize {
        switch self {
        case .leaf:
            CellSize(width: 22, height: 7) // 20×5 content and a one-cell border
        case .split(_, .vertical, _, let first, let second):
            CellSize(
                width: first.minimumOuterSize.width + 1 + second.minimumOuterSize.width,
                height: max(first.minimumOuterSize.height, second.minimumOuterSize.height)
            )
        case .split(_, .horizontal, _, let first, let second):
            CellSize(
                width: max(first.minimumOuterSize.width, second.minimumOuterSize.width),
                height: first.minimumOuterSize.height + 1 + second.minimumOuterSize.height
            )
        }
    }

    public func splitting(
        _ pane: PaneID,
        with newPane: PaneID,
        id: SplitID,
        axis: SplitAxis,
        ratio: SplitRatio = .half
    ) -> PaneTree? {
        guard leafCount < Self.maximumLeaves, leafIDs.contains(pane),
              leafIDs.contains(newPane) == false, containsSplit(id) == false else { return nil }
        return splitReplacingLeaf(pane, with: newPane, id: id, axis: axis, ratio: ratio)
    }

    /// Returns nil when the only leaf is closed or the pane does not exist.
    public func closing(_ pane: PaneID) -> PaneTree? {
        guard leafIDs.contains(pane) else { return nil }
        return closeExistingLeaf(pane)
    }

    /// Collapses the leaf and chooses the nearest pane in its surviving sibling subtree.
    /// The supplied geometry must describe the old tree, before the close.
    public func closing(_ pane: PaneID, using geometry: PaneGeometry) -> PaneCloseResult? {
        guard leafIDs.contains(pane) else { return nil }
        let siblingIDs = siblingLeaves(of: pane) ?? []
        let source = geometry[pane]?.outer
        let focused: PaneID? = siblingIDs.min { lhs, rhs in
            guard let source else { return lhs.rawValue.uuidString < rhs.rawValue.uuidString }
            guard let left = geometry[lhs]?.outer, let right = geometry[rhs]?.outer else {
                return lhs.rawValue.uuidString < rhs.rawValue.uuidString
            }
            let leftDX = left.centerX2 - source.centerX2
            let leftDY = left.centerY2 - source.centerY2
            let rightDX = right.centerX2 - source.centerX2
            let rightDY = right.centerY2 - source.centerY2
            let leftDistance = leftDX * leftDX + leftDY * leftDY
            let rightDistance = rightDX * rightDX + rightDY * rightDY
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            if left.y != right.y { return left.y < right.y }
            if left.x != right.x { return left.x < right.x }
            return lhs.rawValue.uuidString < rhs.rawValue.uuidString
        }
        return PaneCloseResult(tree: closeExistingLeaf(pane), focusedPaneID: focused)
    }

    public func settingRatio(of id: SplitID, to ratio: SplitRatio) -> PaneTree? {
        guard containsSplit(id) else { return nil }
        switch self {
        case .leaf:
            return nil
        case .split(let currentID, let axis, let oldRatio, let first, let second):
            if currentID == id { return .split(id, axis, ratio, first, second) }
            return .split(
                currentID, axis, oldRatio,
                first.settingRatio(of: id, to: ratio) ?? first,
                second.settingRatio(of: id, to: ratio) ?? second
            )
        }
    }

    private func containsSplit(_ id: SplitID) -> Bool {
        switch self {
        case .leaf: false
        case .split(let currentID, _, _, let first, let second):
            currentID == id || first.containsSplit(id) || second.containsSplit(id)
        }
    }

    private func siblingLeaves(of pane: PaneID) -> [PaneID]? {
        switch self {
        case .leaf: return nil
        case .split(_, _, _, let first, let second):
            if first.leafIDs.contains(pane) {
                if case .leaf(let id) = first, id == pane { return second.leafIDs }
                return first.siblingLeaves(of: pane)
            }
            if second.leafIDs.contains(pane) {
                if case .leaf(let id) = second, id == pane { return first.leafIDs }
                return second.siblingLeaves(of: pane)
            }
            return nil
        }
    }

    private func splitReplacingLeaf(
        _ pane: PaneID,
        with newPane: PaneID,
        id: SplitID,
        axis: SplitAxis,
        ratio: SplitRatio
    ) -> PaneTree {
        switch self {
        case .leaf(let current):
            return current == pane ? .split(id, axis, ratio, self, .leaf(newPane)) : self
        case .split(let splitID, let existingAxis, let existingRatio, let first, let second):
            return .split(
                splitID, existingAxis, existingRatio,
                first.splitReplacingLeaf(pane, with: newPane, id: id, axis: axis, ratio: ratio),
                second.splitReplacingLeaf(pane, with: newPane, id: id, axis: axis, ratio: ratio)
            )
        }
    }

    private func closeExistingLeaf(_ pane: PaneID) -> PaneTree? {
        switch self {
        case .leaf(let current): return current == pane ? nil : self
        case .split(let id, let axis, let ratio, let first, let second):
            if first.leafIDs.contains(pane) {
                guard let remaining = first.closeExistingLeaf(pane) else { return second }
                return .split(id, axis, ratio, remaining, second)
            }
            guard let remaining = second.closeExistingLeaf(pane) else { return first }
            return .split(id, axis, ratio, first, remaining)
        }
    }
}

extension PaneTree {
    /// Moves the divider nearest to `pane` on the matching axis by `cells`
    /// (positive grows the first/left/top child). The nearest applicable
    /// ancestor divider is the deepest split with a matching axis on the path
    /// from the root to the pane. Returns nil when no applicable divider
    /// exists or the step cannot move a full cell within subtree minimums.
    public func adjustingDivider(
        near pane: PaneID,
        axis: SplitAxis,
        cells: Int,
        in rect: CellRect
    ) -> PaneTree? {
        guard cells != 0, leafIDs.contains(pane) else { return nil }
        var path: [(id: SplitID, axis: SplitAxis, ratio: SplitRatio, first: PaneTree, second: PaneTree)] = []
        var node: PaneTree = self
        while case .split(let id, let splitAxis, let ratio, let first, let second) = node {
            if first.leafIDs.contains(pane) {
                path.append((id, splitAxis, ratio, first, second))
                node = first
            } else if second.leafIDs.contains(pane) {
                path.append((id, splitAxis, ratio, first, second))
                node = second
            } else {
                return nil
            }
        }
        guard let target = path.last(where: { $0.axis == axis }) else { return nil }
        // Replay placement down the path to recover the target split's rect.
        var splitRect = rect
        for step in path {
            if step.id == target.id { break }
            switch step.axis {
            case .vertical:
                let available = splitRect.width - 1
                let firstWidth = min(
                    available - step.second.minimumOuterSize.width,
                    max(step.first.minimumOuterSize.width, available * step.ratio.thousandths / 1000)
                )
                if step.first.leafIDs.contains(pane) {
                    splitRect = CellRect(x: splitRect.x, y: splitRect.y, width: firstWidth, height: splitRect.height)
                } else {
                    splitRect = CellRect(
                        x: splitRect.x + firstWidth + 1, y: splitRect.y,
                        width: available - firstWidth, height: splitRect.height
                    )
                }
            case .horizontal:
                let available = splitRect.height - 1
                let firstHeight = min(
                    available - step.second.minimumOuterSize.height,
                    max(step.first.minimumOuterSize.height, available * step.ratio.thousandths / 1000)
                )
                if step.first.leafIDs.contains(pane) {
                    splitRect = CellRect(x: splitRect.x, y: splitRect.y, width: splitRect.width, height: firstHeight)
                } else {
                    splitRect = CellRect(
                        x: splitRect.x, y: splitRect.y + firstHeight + 1,
                        width: splitRect.width, height: available - firstHeight
                    )
                }
            }
        }
        let span = axis == .vertical ? splitRect.width - 1 : splitRect.height - 1
        let firstMin = axis == .vertical
            ? target.first.minimumOuterSize.width : target.first.minimumOuterSize.height
        let secondMin = axis == .vertical
            ? target.second.minimumOuterSize.width : target.second.minimumOuterSize.height
        guard span >= firstMin + secondMin else { return nil }
        let current = min(span - secondMin, max(firstMin, span * target.ratio.thousandths / 1000))
        let desired = min(span - secondMin, max(firstMin, current + cells))
        guard desired != current else { return nil }
        // Thousandths rounding can strand a step; nudge within a bounded
        // window until the solved extent matches, else report no movement.
        let center = desired * 1000 / span
        for offset in [0, 1, -1, 2, -2, 3, -3, 4, -4] {
            let thousandths = min(999, max(1, center + offset))
            let solved = min(span - secondMin, max(firstMin, span * thousandths / 1000))
            if solved == desired {
                return settingRatio(of: target.id, to: SplitRatio(thousandths: thousandths))
            }
        }
        return nil
    }
}

public struct PaneCloseResult: Equatable, Sendable {
    public let tree: PaneTree?
    public let focusedPaneID: PaneID?
    public init(tree: PaneTree?, focusedPaneID: PaneID?) {
        self.tree = tree; self.focusedPaneID = focusedPaneID
    }
}

public struct CellSize: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public struct CellRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var right: Int { x + width }
    public var bottom: Int { y + height }
    public var centerX2: Int { 2 * x + width }
    public var centerY2: Int { 2 * y + height }
}

public struct PanePlacement: Equatable, Sendable {
    public let id: PaneID
    public let outer: CellRect
    public let content: CellRect
    public init(id: PaneID, outer: CellRect, content: CellRect) {
        self.id = id; self.outer = outer; self.content = content
    }
}

public struct DividerPlacement: Equatable, Sendable {
    public let id: SplitID
    public let axis: SplitAxis
    public let rect: CellRect
    public init(id: SplitID, axis: SplitAxis, rect: CellRect) {
        self.id = id; self.axis = axis; self.rect = rect
    }
}

/// Pure cell geometry shared by rendering, focus and resize decisions.
public struct PaneGeometry: Equatable, Sendable {
    public let placements: [PanePlacement]
    public let dividers: [DividerPlacement]

    public init(placements: [PanePlacement], dividers: [DividerPlacement]) {
        self.placements = placements
        self.dividers = dividers
    }

    public subscript(_ id: PaneID) -> PanePlacement? {
        placements.first { $0.id == id }
    }

    public static func solve(_ tree: PaneTree, in rect: CellRect) -> PaneGeometry? {
        let ids = tree.leafIDs
        let splitIDs = tree.splitIDs
        guard ids.count <= PaneTree.maximumLeaves, Set(ids).count == ids.count,
              Set(splitIDs).count == splitIDs.count,
              rect.width >= tree.minimumOuterSize.width,
              rect.height >= tree.minimumOuterSize.height else { return nil }
        var placements: [PanePlacement] = []
        var dividers: [DividerPlacement] = []
        place(tree, in: rect, placements: &placements, dividers: &dividers)
        return PaneGeometry(placements: placements, dividers: dividers)
    }

    public func focus(from sourceID: PaneID, toward direction: FocusDirection) -> PaneID? {
        guard let source = self[sourceID] else { return nil }
        return placements
            .filter { $0.id != sourceID && Self.isForward($0.outer, from: source.outer, direction: direction) }
            .min { Self.focusRank($0, from: source, direction: direction) < Self.focusRank($1, from: source, direction: direction) }?
            .id
    }

    private static func place(
        _ tree: PaneTree,
        in rect: CellRect,
        placements: inout [PanePlacement],
        dividers: inout [DividerPlacement]
    ) {
        switch tree {
        case .leaf(let id):
            placements.append(PanePlacement(
                id: id, outer: rect,
                content: CellRect(x: rect.x + 1, y: rect.y + 1, width: rect.width - 2, height: rect.height - 2)
            ))
        case .split(let id, let axis, let ratio, let first, let second):
            switch axis {
            case .vertical:
                let available = rect.width - 1
                let firstWidth = min(
                    available - second.minimumOuterSize.width,
                    max(first.minimumOuterSize.width, available * ratio.thousandths / 1000)
                )
                let firstRect = CellRect(x: rect.x, y: rect.y, width: firstWidth, height: rect.height)
                let secondRect = CellRect(x: rect.x + firstWidth + 1, y: rect.y,
                                          width: available - firstWidth, height: rect.height)
                dividers.append(DividerPlacement(id: id, axis: axis,
                                                 rect: CellRect(x: rect.x + firstWidth, y: rect.y,
                                                                width: 1, height: rect.height)))
                place(first, in: firstRect, placements: &placements, dividers: &dividers)
                place(second, in: secondRect, placements: &placements, dividers: &dividers)
            case .horizontal:
                let available = rect.height - 1
                let firstHeight = min(
                    available - second.minimumOuterSize.height,
                    max(first.minimumOuterSize.height, available * ratio.thousandths / 1000)
                )
                let firstRect = CellRect(x: rect.x, y: rect.y, width: rect.width, height: firstHeight)
                let secondRect = CellRect(x: rect.x, y: rect.y + firstHeight + 1,
                                          width: rect.width, height: available - firstHeight)
                dividers.append(DividerPlacement(id: id, axis: axis,
                                                 rect: CellRect(x: rect.x, y: rect.y + firstHeight,
                                                                width: rect.width, height: 1)))
                place(first, in: firstRect, placements: &placements, dividers: &dividers)
                place(second, in: secondRect, placements: &placements, dividers: &dividers)
            }
        }
    }

    private static func isForward(_ candidate: CellRect, from source: CellRect, direction: FocusDirection) -> Bool {
        switch direction {
        case .left: candidate.centerX2 < source.centerX2
        case .right: candidate.centerX2 > source.centerX2
        case .up: candidate.centerY2 < source.centerY2
        case .down: candidate.centerY2 > source.centerY2
        }
    }

    private static func focusRank(
        _ candidate: PanePlacement,
        from source: PanePlacement,
        direction: FocusDirection
    ) -> FocusRank {
        let horizontal = direction == .left || direction == .right
        let sourceStart = horizontal ? source.outer.y : source.outer.x
        let sourceEnd = horizontal ? source.outer.bottom : source.outer.right
        let candidateStart = horizontal ? candidate.outer.y : candidate.outer.x
        let candidateEnd = horizontal ? candidate.outer.bottom : candidate.outer.right
        let overlap = min(sourceEnd, candidateEnd) - max(sourceStart, candidateStart)
        let perpendicularDistance = max(0, max(sourceStart - candidateEnd, candidateStart - sourceEnd))
        let forwardDistance: Int
        switch direction {
        case .left: forwardDistance = max(0, source.outer.x - candidate.outer.right)
        case .right: forwardDistance = max(0, candidate.outer.x - source.outer.right)
        case .up: forwardDistance = max(0, source.outer.y - candidate.outer.bottom)
        case .down: forwardDistance = max(0, candidate.outer.y - source.outer.bottom)
        }
        let dx = candidate.outer.centerX2 - source.outer.centerX2
        let dy = candidate.outer.centerY2 - source.outer.centerY2
        return FocusRank(
            lacksOverlap: overlap <= 0,
            forwardDistance: forwardDistance,
            perpendicularDistance: perpendicularDistance,
            centerDistanceSquared: dx * dx + dy * dy,
            top: candidate.outer.y,
            left: candidate.outer.x,
            id: candidate.id.rawValue.uuidString
        )
    }
}

private struct FocusRank: Comparable {
    let lacksOverlap: Bool
    let forwardDistance: Int
    let perpendicularDistance: Int
    let centerDistanceSquared: Int
    let top: Int
    let left: Int
    let id: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.lacksOverlap != rhs.lacksOverlap { return lhs.lacksOverlap == false }
        if lhs.forwardDistance != rhs.forwardDistance { return lhs.forwardDistance < rhs.forwardDistance }
        if lhs.perpendicularDistance != rhs.perpendicularDistance {
            return lhs.perpendicularDistance < rhs.perpendicularDistance
        }
        if lhs.centerDistanceSquared != rhs.centerDistanceSquared {
            return lhs.centerDistanceSquared < rhs.centerDistanceSquared
        }
        if lhs.top != rhs.top { return lhs.top < rhs.top }
        if lhs.left != rhs.left { return lhs.left < rhs.left }
        return lhs.id < rhs.id
    }
}
