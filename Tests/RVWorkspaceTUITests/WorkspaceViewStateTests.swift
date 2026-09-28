import Foundation
import Testing
import RVDomain
@testable import RVWorkspaceTUI

private let firstPane = PaneID(UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
private let secondPane = PaneID(UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)
private let firstTab = TabID(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)
private let secondTab = TabID(UUID(uuidString: "00000000-0000-0000-0000-000000000022")!)
private let firstSplit = SplitID(UUID(uuidString: "00000000-0000-0000-0000-000000000031")!)

@Test func emptyViewAndNewTabHaveValidOwnership() {
    let empty = WorkspaceView(id: ViewID())
    #expect(empty.tabs.isEmpty)
    #expect(empty.activeTabID == nil)
    #expect(empty.validate().isEmpty)
    let view = empty.addingTab(id: firstTab, paneID: firstPane)!
    #expect(view.tabs.map(\.id) == [firstTab])
    #expect(view.activeTabID == firstTab)
    #expect(view.panes[firstPane]?.lifecycle == .empty)
    #expect(view.validate().isEmpty)
}

@Test func splitPreflightsGeometryBeforeAddingAnEmptyPane() {
    let view = WorkspaceView(id: ViewID()).addingTab(id: firstTab, paneID: firstPane)!
    #expect(view.splittingFocusedPane(axis: .vertical, in: CellRect(x: 0, y: 0, width: 44, height: 7),
                                       newPaneID: secondPane, splitID: firstSplit) == nil)
    #expect(view.panes.count == 1)
    let split = view.splittingFocusedPane(axis: .vertical, in: CellRect(x: 0, y: 0, width: 45, height: 7),
                                          newPaneID: secondPane, splitID: firstSplit)!
    #expect(split.activeTab?.tree.leafIDs == [firstPane, secondPane])
    #expect(split.activeTab?.focusedPaneID == secondPane)
    #expect(split.panes[secondPane]?.binding == nil)
    #expect(split.validate().isEmpty)
}

@Test func closingPaneCollapsesTreeAndClosingFinalTabLeavesAnIntentionallyEmptyView() {
    let view = WorkspaceView(id: ViewID()).addingTab(id: firstTab, paneID: firstPane)!
        .splittingFocusedPane(axis: .horizontal, in: CellRect(x: 0, y: 0, width: 22, height: 15),
                              newPaneID: secondPane, splitID: firstSplit)!
    let geometry = PaneGeometry.solve(view.activeTab!.tree, in: CellRect(x: 0, y: 0, width: 22, height: 15))!
    let one = view.closingFocusedPane(using: geometry)!
    #expect(one.activeTab?.tree == .leaf(firstPane))
    #expect(one.activeTab?.focusedPaneID == firstPane)
    #expect(one.panes[secondPane] == nil)
    #expect(one.validate().isEmpty)
    let last = one.closingFocusedPane(using: PaneGeometry.solve(one.activeTab!.tree,
                                                                 in: CellRect(x: 0, y: 0, width: 22, height: 7))!)!
    #expect(last.tabs.isEmpty)
    #expect(last.panes.isEmpty)
    #expect(last.activeTabID == nil)
    #expect(last.validate().isEmpty)
}

@Test func tabsWrapAndKeepIndependentFocusAndZoom() {
    let first = WorkspaceView(id: ViewID()).addingTab(id: firstTab, paneID: firstPane)!
    let two = first.addingTab(id: secondTab, paneID: secondPane)!
    #expect(two.activeTabID == secondTab)
    #expect(two.switchingTab(by: 1)?.activeTabID == firstTab)
    #expect(two.switchingTab(by: -1)?.activeTabID == firstTab)
    let zoomed = two.togglingZoom()!
    #expect(zoomed.activeTab?.zoomedPaneID == secondPane)
    #expect(zoomed.activatingTab(firstTab)?.activeTab?.zoomedPaneID == nil)
    #expect(zoomed.validate().isEmpty)
}

@Test func bindingReplacementKeepsPaneIdentityAndRejectsDuplicateRuntime() {
    let workspace = WorkspaceSessionID(rawValue: UUID())
    let oldRuntime = RuntimeSessionID(rawValue: UUID())
    let newRuntime = RuntimeSessionID(rawValue: UUID())
    let old = RuntimeBinding(workspace: workspace, runtime: oldRuntime, generation: 1)
    let new = RuntimeBinding(workspace: workspace, runtime: newRuntime, generation: 2)
    let view = WorkspaceView(id: ViewID()).addingTab(id: firstTab, paneID: firstPane)!
    let running = view.updatingPane(WorkspacePane(id: firstPane, binding: old, lifecycle: .running))!
    let replaced = running.updatingPane(WorkspacePane(id: firstPane, binding: new, lifecycle: .attaching,
                                                       lastOutcome: .exited(0)))!
    #expect(replaced.panes[firstPane]?.id == firstPane)
    #expect(replaced.panes[firstPane]?.binding?.runtime == newRuntime)
    #expect(replaced.validate().isEmpty)
    let withSecond = replaced.addingTab(id: secondTab, paneID: secondPane)!
    #expect(withSecond.updatingPane(WorkspacePane(id: secondPane, binding: new, lifecycle: .running)) == nil)
}

@Test func focusEquivalenceIgnoresSelectionButNotBindingsOrStructure() {
    let view = WorkspaceView(id: ViewID()).addingTab(id: firstTab, paneID: firstPane)!
        .splittingFocusedPane(axis: .vertical, in: CellRect(x: 0, y: 0, width: 45, height: 7),
                              newPaneID: secondPane, splitID: firstSplit)!
        .addingTab(id: secondTab, paneID: PaneID())!
    #expect(view.equalIgnoringFocus(view))
    // Focus and active-tab moves are selection-only: async persistence.
    let onFirst = view.activatingTab(firstTab)!
    #expect(onFirst.focusingPane(firstPane)!.equalIgnoringFocus(onFirst))
    #expect(onFirst.equalIgnoringFocus(view))
    // Bindings, lifecycles, trees, titles, and zoom are durable: sync commit.
    let bound = view.updatingPane(WorkspacePane(
        id: firstPane,
        binding: RuntimeBinding(workspace: WorkspaceSessionID(rawValue: UUID()),
                               runtime: RuntimeSessionID(rawValue: UUID()), generation: 1),
        lifecycle: .running))!
    #expect(bound.equalIgnoringFocus(view) == false)
    let exited = bound.updatingPane(WorkspacePane(
        id: firstPane, binding: bound.panes[firstPane]!.binding, lifecycle: .exited,
        lastOutcome: .exited(0)))!
    #expect(exited.equalIgnoringFocus(bound) == false)
    let zoomed = view.togglingZoom()!
    #expect(zoomed.equalIgnoringFocus(view) == false)
    let retitled = view.updatingPane(WorkspacePane(id: firstPane, userTitle: "logs"))!
    #expect(retitled.equalIgnoringFocus(view) == false)
}

@Test func validationDetectsBrokenReferencesAndDuplicateLeaves() {
    let duplicate = WorkspaceView(id: ViewID(), tabs: [
        WorkspaceTab(id: firstTab, tree: .leaf(firstPane), focusedPaneID: firstPane),
        WorkspaceTab(id: secondTab, tree: .leaf(firstPane), focusedPaneID: firstPane),
    ], activeTabID: firstTab, panes: [firstPane: WorkspacePane(id: firstPane)])
    #expect(duplicate.validate().contains(.duplicatePaneLeaf(firstPane)))
    let missing = WorkspaceView(id: ViewID(), tabs: [
        WorkspaceTab(id: firstTab, tree: .leaf(firstPane), focusedPaneID: secondPane),
    ], activeTabID: firstTab, panes: [:])
    #expect(missing.validate().contains(.missingPane(firstPane)))
    #expect(missing.validate().contains(.invalidFocus(firstTab)))
}

@Test func validationRejectsMismatchedPaneIdentityAndRepeatedSplitIdentity() {
    let thirdPane = PaneID()
    let repeated = PaneTree.split(firstSplit, .vertical, .half, .leaf(firstPane),
                                  .split(firstSplit, .horizontal, .half, .leaf(secondPane), .leaf(thirdPane)))
    let view = WorkspaceView(id: ViewID(), tabs: [
        WorkspaceTab(id: firstTab, tree: repeated, focusedPaneID: firstPane),
    ], activeTabID: firstTab, panes: [
        firstPane: WorkspacePane(id: secondPane),
        secondPane: WorkspacePane(id: secondPane),
        thirdPane: WorkspacePane(id: thirdPane),
    ])
    #expect(view.validate().contains(.mismatchedPaneID(firstPane)))
    #expect(view.validate().contains(.duplicateSplit(firstSplit)))
}

@Test func totalPaneLimitCountsHiddenTabs() {
    var view = WorkspaceView(id: ViewID())
    for _ in 0..<8 { view = view.addingTab()! }
    #expect(view.tabs.count == 8)
    #expect(view.panes.count == 8)
    #expect(view.addingTab() == nil)
}

@Test func splitIDMustBeUniqueAcrossTabs() {
    let thirdPane = PaneID()
    let fourthPane = PaneID()
    let first = WorkspaceView(id: ViewID()).addingTab(id: firstTab, paneID: firstPane)!
        .splittingFocusedPane(axis: .vertical, in: CellRect(x: 0, y: 0, width: 45, height: 7),
                              newPaneID: secondPane, splitID: firstSplit)!
    let second = first.addingTab(id: secondTab, paneID: thirdPane)!
    #expect(second.splittingFocusedPane(axis: .vertical,
                                        in: CellRect(x: 0, y: 0, width: 45, height: 7),
                                        newPaneID: fourthPane, splitID: firstSplit) == nil)
    #expect(second.validate().isEmpty)
}
