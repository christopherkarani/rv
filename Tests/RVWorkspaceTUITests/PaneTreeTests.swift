import Foundation
import Testing
@testable import RVWorkspaceTUI

@Test func oneLeafListsItself() {
    let id = PaneID()
    let tree = PaneTree.leaf(id)
    #expect(tree.paneIDs == [id])
    #expect(tree.isUniquelyIdentified)
    #expect(tree.firstLeaf == id)
}

@Test func verticalAndHorizontalSplitsKeepBothLeaves() throws {
    let first = PaneID()
    let second = PaneID()
    let third = PaneID()
    let vertical = try PaneTree.leaf(first).splitting(first, axis: .vertical, inserted: second).get()
    let nested = try vertical.splitting(second, axis: .horizontal, inserted: third).get()
    #expect(nested.paneIDs == [first, second, third])
    #expect(nested.isUniquelyIdentified)
    guard case .split(.vertical, let ratio, .leaf, .split(.horizontal, _, .leaf(let foundSecond), .leaf(let foundThird))) = nested.shape else {
        Issue.record("nested split shape")
        return
    }
    #expect(ratio == .even)
    #expect(foundSecond == second)
    #expect(foundThird == third)
}

@Test func closingALeafCollapsesItsParent() throws {
    let first = PaneID()
    let second = PaneID()
    let third = PaneID()
    let vertical = try PaneTree.leaf(first).splitting(first, axis: .vertical, inserted: second).get()
    let nested = try vertical.splitting(second, axis: .horizontal, inserted: third).get()
    let closed = try nested.closing(second).get()
    #expect(closed.tree.paneIDs == [first, third])
    #expect(closed.focus == third)
    let root = try closed.tree.closing(first).get()
    #expect(root.tree.paneIDs == [third])
    let empty = try root.tree.closing(third).get()
    #expect(empty.tree == .empty)
    #expect(empty.focus == nil)
}

@Test func duplicatePaneIsRejectedAndTheTreeStaysPut() throws {
    let first = PaneID()
    let tree = PaneTree.leaf(first)
    #expect(tree.splitting(first, axis: .vertical, inserted: first) == .failure(.duplicatePane))
    #expect(tree == .leaf(first))
    switch tree.closing(PaneID()) {
    case .failure(.missingPane):
        break
    default:
        Issue.record("missing pane close should fail")
    }
    #expect(PaneTree.balanced([first, first]) == .failure(.duplicatePane))
}

@Test func balancedTreeIsDeterministic() throws {
    let ids = (0..<3).map { _ in PaneID() }
    let tree = try PaneTree.balanced(ids).get()
    #expect(tree.paneIDs == ids)
    guard case .split(.vertical, _, .leaf(let only), .split(.horizontal, _, _, _)) = tree.shape else {
        Issue.record("three panes alternate axes")
        return
    }
    #expect(only == ids[0])
}

@Test func splitRatiosAreClampedAndDriveNestedGeometry() throws {
    let ids = (0..<3).map { _ in PaneID() }
    let ratio = SplitRatio(firstBasisPoints: 7_000)
    #expect(SplitRatio(firstBasisPoints: -5).firstBasisPoints == 0)
    #expect(SplitRatio(firstBasisPoints: 12_000).firstBasisPoints == 10_000)
    let root = try PaneTree.leaf(ids[0])
        .splitting(ids[0], axis: .vertical, ratio: ratio, inserted: ids[1]).get()
    let nested = try root.splitting(ids[1], axis: .horizontal, inserted: ids[2]).get()
    let frames = PaneLayout.frames(of: nested, in: PaneRect(x: 0, y: 0, width: 100, height: 40))
    #expect(frames[ids[0]] == PaneRect(x: 0, y: 0, width: 70, height: 40))
    #expect(frames[ids[1]] == PaneRect(x: 70, y: 0, width: 30, height: 20))
    #expect(frames[ids[2]] == PaneRect(x: 70, y: 20, width: 30, height: 20))
}

@Test func geometryFocusIsDeterministicForEqualDistances() {
    let origin = PaneID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let upper = PaneID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let lower = PaneID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    let frames = [
        origin: PaneRect(x: 0, y: 0, width: 20, height: 20),
        upper: PaneRect(x: 20, y: 0, width: 20, height: 10),
        lower: PaneRect(x: 20, y: 10, width: 20, height: 10),
    ]
    #expect(PaneLayout.focus(from: origin, direction: .right, frames: frames) == upper)
}

@Test func directionalFocusFollowsGeometry() {
    let left = PaneID()
    let upper = PaneID()
    let lower = PaneID()
    let frames = [
        left: PaneRect(x: 0, y: 0, width: 40, height: 20),
        upper: PaneRect(x: 40, y: 0, width: 40, height: 10),
        lower: PaneRect(x: 40, y: 10, width: 40, height: 10),
    ]
    #expect(PaneLayout.focus(from: left, direction: .right, frames: frames) == upper)
    #expect(PaneLayout.focus(from: upper, direction: .down, frames: frames) == lower)
    #expect(PaneLayout.focus(from: lower, direction: .left, frames: frames) == left)
    #expect(PaneLayout.focus(from: upper, direction: .up, frames: frames) == nil)
    #expect(PaneLayout.focus(from: lower, direction: .right, frames: frames) == nil)
}

@Test func prefixConsumesControlGAndUnknownKeys() {
    var mode = CommandMode.terminal
    let entered = CommandPrefix.route(.control("g"), mode: mode, launcher: [])
    mode = entered.0
    #expect(mode == .prefix)
    #expect(entered.1 == nil)
    let unknown = CommandPrefix.route(.character("q"), mode: mode, launcher: [])
    #expect(unknown == (.terminal, nil))
    let plain = CommandPrefix.route(.control("c"), mode: .terminal, launcher: [])
    #expect(plain.1 == .send(Data([0x03])))
}

@Test func prefixCommandsDoNotEncodeThePrefix() {
    #expect(CommandPrefix.route(.character("v"), mode: .prefix, launcher: []).1 == .splitVertical)
    #expect(CommandPrefix.route(.character("s"), mode: .prefix, launcher: []).1 == .splitHorizontal)
    #expect(CommandPrefix.route(.character("d"), mode: .prefix, launcher: []).1 == .detach)
    #expect(CommandPrefix.route(.character("?"), mode: .prefix, launcher: []).1 == .help)
    #expect(CommandPrefix.route(.escape, mode: .help, launcher: []).0 == .terminal)
    #expect(TerminalInputEncoder.bytes(for: .enter) == Data([0x0d]))
    #expect(TerminalInputEncoder.bytes(for: .control("c")) == Data([0x03]))
}

@Test func resizeCoalescerSendsOnlyAStableChange() {
    var gate = ResizeCoalescer()
    gate.recordLaunch(rows: 24, columns: 80)
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(gate.propose(rows: 24, columns: 80, now: now) == nil)
    #expect(gate.propose(rows: 40, columns: 100, now: now) == nil)
    #expect(gate.propose(rows: 41, columns: 100, now: now.addingTimeInterval(0.01)) == nil)
    let sent = gate.propose(rows: 41, columns: 100, now: now.addingTimeInterval(0.08))
    #expect(sent?.rows == 41)
    #expect(sent?.columns == 100)
    #expect(gate.propose(rows: 41, columns: 100, now: now.addingTimeInterval(1)) == nil)
    #expect(gate.propose(rows: 900, columns: 1, now: now)?.rows == nil)
    let clamped = gate.propose(rows: 900, columns: 1, now: now.addingTimeInterval(1.05))
    #expect(clamped?.rows == 512)
    #expect(clamped?.columns == 1)
}
