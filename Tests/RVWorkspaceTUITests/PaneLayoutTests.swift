import Foundation
import Testing
@testable import RVWorkspaceTUI

private let a = PaneID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
private let b = PaneID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
private let c = PaneID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
private let d = PaneID(UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
private let split1 = SplitID(UUID(uuidString: "10000000-0000-0000-0000-000000000001")!)
private let split2 = SplitID(UUID(uuidString: "10000000-0000-0000-0000-000000000002")!)

@Test func paneTreeSplitNestAndCollapse() {
    let initial = PaneTree.leaf(a)
    let right = initial.splitting(a, with: b, id: split1, axis: .vertical)!
    let nested = right.splitting(b, with: c, id: split2, axis: .horizontal)!
    #expect(nested.leafIDs == [a, b, c])
    #expect(nested.leafCount == 3)
    #expect(nested.closing(b)?.leafIDs == [a, c])
    #expect(nested.closing(a)?.leafIDs == [b, c])
    #expect(PaneTree.leaf(a).closing(a) == nil)
    #expect(nested.splitting(a, with: c, id: SplitID(), axis: .vertical) == nil)
    #expect(nested.splitting(d, with: PaneID(), id: SplitID(), axis: .vertical) == nil)
}

@Test func eightLeavesIsTheSupportedLimit() {
    var tree = PaneTree.leaf(a)
    for _ in 1..<8 {
        tree = tree.splitting(a, with: PaneID(), id: SplitID(), axis: .vertical)!
    }
    #expect(tree.leafCount == 8)
    #expect(tree.splitting(a, with: PaneID(), id: SplitID(), axis: .vertical) == nil)
}

@Test func geometryUsesOneCellDividersAndDeterministicRounding() {
    let tree = PaneTree.leaf(a).splitting(a, with: b, id: split1, axis: .vertical)!
    let solved = PaneGeometry.solve(tree, in: CellRect(x: 0, y: 0, width: 51, height: 7))!
    #expect(solved[a]?.outer == CellRect(x: 0, y: 0, width: 25, height: 7))
    #expect(solved[b]?.outer == CellRect(x: 26, y: 0, width: 25, height: 7))
    #expect(solved[a]?.content == CellRect(x: 1, y: 1, width: 23, height: 5))
    #expect(solved.dividers == [DividerPlacement(id: split1, axis: .vertical, rect: CellRect(x: 25, y: 0, width: 1, height: 7))])
    #expect(PaneGeometry.solve(tree, in: CellRect(x: 0, y: 0, width: 44, height: 7)) == nil)
    #expect(tree.minimumOuterSize == CellSize(width: 45, height: 7))
}

@Test func nestedGeometryAndRatioClamping() {
    let right = PaneTree.leaf(b).splitting(b, with: c, id: split2, axis: .horizontal)!
    let tree = PaneTree.split(split1, .vertical, .half, .leaf(a), right)
    #expect(tree.minimumOuterSize == CellSize(width: 45, height: 15))
    let widened = tree.settingRatio(of: split1, to: SplitRatio(thousandths: 900))!
    let solved = PaneGeometry.solve(widened, in: CellRect(x: 0, y: 0, width: 70, height: 20))!
    #expect(solved[a]?.outer.width == 47)
    #expect(solved[b]?.outer.width == 22)
    #expect(solved[b]?.outer.height == 9)
    #expect(solved[c]?.outer.height == 10)
    #expect(tree.settingRatio(of: SplitID(), to: .half) == nil)
}

@Test func directionalFocusPrefersOverlapThenForwardDistanceAndNeverWraps() {
    let placements: [PanePlacement] = [
        .init(id: a, outer: CellRect(x: 20, y: 20, width: 10, height: 10), content: CellRect(x: 21, y: 21, width: 8, height: 8)),
        .init(id: b, outer: CellRect(x: 31, y: 20, width: 10, height: 10), content: CellRect(x: 32, y: 21, width: 8, height: 8)),
        .init(id: c, outer: CellRect(x: 30, y: 40, width: 10, height: 10), content: CellRect(x: 31, y: 41, width: 8, height: 8)),
        .init(id: d, outer: CellRect(x: 0, y: 20, width: 10, height: 10), content: CellRect(x: 1, y: 21, width: 8, height: 8)),
    ]
    let geometry = PaneGeometry(placements: placements, dividers: [])
    #expect(geometry.focus(from: a, toward: .right) == b)
    #expect(geometry.focus(from: a, toward: .left) == d)
    #expect(geometry.focus(from: b, toward: .right) == nil)
    #expect(geometry.focus(from: a, toward: .up) == nil)
}

@Test func directionalFocusBreaksEqualDistancesByTopLeftThenID() {
    let source = PanePlacement(id: a, outer: CellRect(x: 0, y: 10, width: 10, height: 10),
                               content: CellRect(x: 1, y: 11, width: 8, height: 8))
    let lower = PanePlacement(id: b, outer: CellRect(x: 11, y: 15, width: 10, height: 10),
                              content: CellRect(x: 12, y: 16, width: 8, height: 8))
    let upper = PanePlacement(id: c, outer: CellRect(x: 11, y: 5, width: 10, height: 10),
                              content: CellRect(x: 12, y: 6, width: 8, height: 8))
    let geometry = PaneGeometry(placements: [source, lower, upper], dividers: [])
    #expect(geometry.focus(from: a, toward: .right) == c)
}

@Test func closeFocusComesFromSurvivingSiblingSubtree() {
    let sibling = PaneTree.leaf(b).splitting(b, with: c, id: split2, axis: .horizontal)!
    let tree = PaneTree.split(split1, .vertical, .half, .leaf(a), sibling)
    let placements: [PanePlacement] = [
        .init(id: a, outer: CellRect(x: 0, y: 20, width: 10, height: 10), content: CellRect(x: 1, y: 21, width: 8, height: 8)),
        .init(id: b, outer: CellRect(x: 11, y: 0, width: 10, height: 10), content: CellRect(x: 12, y: 1, width: 8, height: 8)),
        .init(id: c, outer: CellRect(x: 11, y: 20, width: 10, height: 10), content: CellRect(x: 12, y: 21, width: 8, height: 8)),
    ]
    let result = tree.closing(a, using: PaneGeometry(placements: placements, dividers: []))
    #expect(result?.tree == sibling)
    #expect(result?.focusedPaneID == c)
}

@Test func identifiersAndTreeRoundTripWithoutLosingIdentity() throws {
    let tree = PaneTree.leaf(a).splitting(a, with: b, id: split1, axis: .horizontal)!
    #expect(try JSONDecoder().decode(PaneTree.self, from: JSONEncoder().encode(tree)) == tree)
    let tab = TabID()
    let view = ViewID()
    #expect(try JSONDecoder().decode(TabID.self, from: JSONEncoder().encode(tab)) == tab)
    #expect(try JSONDecoder().decode(ViewID.self, from: JSONEncoder().encode(view)) == view)
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(SplitRatio.self, from: Data("1000".utf8))
    }
}

@Test func persistedPaneTreeRejectsDepthBeyondEightLeaves() throws {
    var tree = PaneTree.leaf(a)
    for _ in 0..<8 {
        tree = .split(SplitID(), .vertical, .half, tree, .leaf(PaneID()))
    }
    let encoded = try JSONEncoder().encode(tree)
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(PaneTree.self, from: encoded)
    }
}
