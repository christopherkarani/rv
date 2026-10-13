import Foundation
import RVDomain

/// A saved reference names a host runtime; it is not an admission token or authority.
/// The persisted pane-identity key, scoped by workspace so a restored
/// layout can only reconcile against its own workspace. Operational
/// keys (`PaneBindingKey`, `PrefixTarget`) derive from it per reduce;
/// see `PaneBindingKey` for why the three do not unify.
public struct RuntimeBinding: Equatable, Sendable {
    public let workspace: WorkspaceSessionID
    public let runtime: RuntimeSessionID
    public let generation: UInt64

    public init(workspace: WorkspaceSessionID, runtime: RuntimeSessionID, generation: UInt64) {
        self.workspace = workspace
        self.runtime = runtime
        self.generation = generation
    }
}

public enum WorkspacePaneLifecycle: String, Codable, Sendable {
    case empty
    case launching
    case attaching
    case running
    case exited
    case launchFailed
    case disconnected
    case missing
}

public enum WorkspacePaneOutcome: Equatable, Sendable {
    case exited(Int32)
    case launchFailed(String)
}

/// Presentation identity survives process exit and relaunch.
public struct WorkspacePane: Equatable, Sendable {
    public let id: PaneID
    public var userTitle: String?
    public var binding: RuntimeBinding?
    public var lifecycle: WorkspacePaneLifecycle
    public var lastOutcome: WorkspacePaneOutcome?

    public init(
        id: PaneID,
        userTitle: String? = nil,
        binding: RuntimeBinding? = nil,
        lifecycle: WorkspacePaneLifecycle = .empty,
        lastOutcome: WorkspacePaneOutcome? = nil
    ) {
        self.id = id
        self.userTitle = userTitle
        self.binding = binding
        self.lifecycle = lifecycle
        self.lastOutcome = lastOutcome
    }
}

public struct WorkspaceTab: Equatable, Sendable {
    public let id: TabID
    public var userTitle: String?
    public var tree: PaneTree
    public var focusedPaneID: PaneID
    /// Zoom changes presentation only; the tree and runtimes remain intact.
    public var zoomedPaneID: PaneID?

    public init(
        id: TabID,
        userTitle: String? = nil,
        tree: PaneTree,
        focusedPaneID: PaneID,
        zoomedPaneID: PaneID? = nil
    ) {
        self.id = id
        self.userTitle = userTitle
        self.tree = tree
        self.focusedPaneID = focusedPaneID
        self.zoomedPaneID = zoomedPaneID
    }
}

public enum WorkspaceViewIssue: Equatable, Sendable {
    case tooManyTabs
    case tooManyPanes
    case duplicateTab(TabID)
    case duplicatePaneLeaf(PaneID)
    case mismatchedPaneID(PaneID)
    case missingPane(PaneID)
    case orphanPane(PaneID)
    case duplicateSplit(SplitID)
    case invalidActiveTab
    case invalidFocus(TabID)
    case invalidZoom(TabID)
    case duplicateRuntime(RuntimeSessionID)
}

/// One client's independent presentation of host-owned runtimes.
public struct WorkspaceView: Equatable, Sendable {
    public let id: ViewID
    public private(set) var tabs: [WorkspaceTab]
    public private(set) var activeTabID: TabID?
    public private(set) var panes: [PaneID: WorkspacePane]

    public init(
        id: ViewID,
        tabs: [WorkspaceTab] = [],
        activeTabID: TabID? = nil,
        panes: [PaneID: WorkspacePane] = [:]
    ) {
        self.id = id
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.panes = panes
    }

    public var activeTab: WorkspaceTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    public var focusedPane: WorkspacePane? {
        guard let paneID = activeTab?.focusedPaneID else { return nil }
        return panes[paneID]
    }

    /// Structural equality for crash-consistency: two views are
    /// focus-equivalent when everything but the selection matches (active
    /// tab, per-tab focus). Bindings, lifecycles, trees, titles, and zoom
    /// all count as durable state and commit synchronously on change;
    /// focus-only moves persist through the async save pump instead, so
    /// arrow-key navigation never blocks on a filesystem fsync.
    public func equalIgnoringFocus(_ other: WorkspaceView) -> Bool {
        guard id == other.id, panes == other.panes, tabs.count == other.tabs.count else { return false }
        for (mine, theirs) in zip(tabs, other.tabs) {
            guard mine.id == theirs.id, mine.userTitle == theirs.userTitle,
                  mine.tree == theirs.tree, mine.zoomedPaneID == theirs.zoomedPaneID else { return false }
        }
        return true
    }

    public func validate() -> [WorkspaceViewIssue] {
        var issues: [WorkspaceViewIssue] = []
        if tabs.count > PaneTree.maximumLeaves { issues.append(.tooManyTabs) }
        if panes.count > PaneTree.maximumLeaves { issues.append(.tooManyPanes) }
        if (activeTabID == nil) != tabs.isEmpty ||
            (activeTabID != nil && activeTab == nil) { issues.append(.invalidActiveTab) }

        var seenTabs: Set<TabID> = []
        var seenLeaves: Set<PaneID> = []
        var seenSplits: Set<SplitID> = []
        for tab in tabs {
            if seenTabs.insert(tab.id).inserted == false { issues.append(.duplicateTab(tab.id)) }
            let leafIDs = tab.tree.leafIDs
            for id in tab.tree.splitIDs where seenSplits.insert(id).inserted == false {
                issues.append(.duplicateSplit(id))
            }
            for id in leafIDs {
                if seenLeaves.insert(id).inserted == false { issues.append(.duplicatePaneLeaf(id)) }
                if panes[id] == nil { issues.append(.missingPane(id)) }
            }
            if leafIDs.contains(tab.focusedPaneID) == false { issues.append(.invalidFocus(tab.id)) }
            if let zoom = tab.zoomedPaneID, leafIDs.contains(zoom) == false {
                issues.append(.invalidZoom(tab.id))
            }
        }
        for (id, pane) in panes {
            if id != pane.id { issues.append(.mismatchedPaneID(id)) }
            if seenLeaves.contains(id) == false { issues.append(.orphanPane(id)) }
        }
        if seenLeaves.count > PaneTree.maximumLeaves { issues.append(.tooManyPanes) }

        var seenRuntimes: Set<RuntimeSessionID> = []
        for pane in panes.values {
            if let runtime = pane.binding?.runtime, seenRuntimes.insert(runtime).inserted == false {
                issues.append(.duplicateRuntime(runtime))
            }
        }
        return issues
    }

    /// Adds an empty pane. The reducer may launch a default shell only after this succeeds.
    public func addingTab(id tabID: TabID = TabID(), paneID: PaneID = PaneID()) -> WorkspaceView? {
        guard validate().isEmpty, tabs.count < PaneTree.maximumLeaves,
              panes.count < PaneTree.maximumLeaves,
              tabs.contains(where: { $0.id == tabID }) == false,
              panes[paneID] == nil else { return nil }
        var next = self
        next.tabs.append(WorkspaceTab(id: tabID, tree: .leaf(paneID), focusedPaneID: paneID))
        next.panes[paneID] = WorkspacePane(id: paneID)
        next.activeTabID = tabID
        return next
    }

    /// A failed geometry preflight leaves the view untouched and needs no host launch.
    public func splittingFocusedPane(
        axis: SplitAxis,
        in rect: CellRect,
        newPaneID: PaneID = PaneID(),
        splitID: SplitID = SplitID()
    ) -> WorkspaceView? {
        guard validate().isEmpty, panes.count < PaneTree.maximumLeaves,
              panes[newPaneID] == nil, let activeTabID,
              tabs.contains(where: { $0.tree.splitIDs.contains(splitID) }) == false,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return nil }
        let tab = tabs[index]
        guard let tree = tab.tree.splitting(tab.focusedPaneID, with: newPaneID, id: splitID, axis: axis),
              PaneGeometry.solve(tree, in: rect) != nil else { return nil }
        var next = self
        next.tabs[index].tree = tree
        next.tabs[index].focusedPaneID = newPaneID
        next.tabs[index].zoomedPaneID = nil
        next.panes[newPaneID] = WorkspacePane(id: newPaneID)
        return next
    }

    /// Removing a pane removes only its presentation. Its host runtime is unchanged.
    public func closingFocusedPane(using geometry: PaneGeometry) -> WorkspaceView? {
        guard validate().isEmpty, let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return nil }
        let tab = tabs[index]
        guard let close = tab.tree.closing(tab.focusedPaneID, using: geometry) else { return nil }
        var next = self
        next.panes.removeValue(forKey: tab.focusedPaneID)
        if let tree = close.tree {
            next.tabs[index].tree = tree
            next.tabs[index].focusedPaneID = close.focusedPaneID ?? tree.leafIDs[0]
            if let zoom = tab.zoomedPaneID, tree.leafIDs.contains(zoom) == false {
                next.tabs[index].zoomedPaneID = nil
            }
        } else {
            next.tabs.remove(at: index)
            next.activeTabID = next.tabs.isEmpty ? nil : next.tabs[min(index, next.tabs.count - 1)].id
        }
        return next
    }

    public func activatingTab(_ id: TabID) -> WorkspaceView? {
        guard tabs.contains(where: { $0.id == id }) else { return nil }
        var next = self
        next.activeTabID = id
        return next
    }

    public func switchingTab(by offset: Int) -> WorkspaceView? {
        guard let activeTabID, let index = tabs.firstIndex(where: { $0.id == activeTabID }),
              tabs.isEmpty == false else { return nil }
        let nextIndex = ((index + offset) % tabs.count + tabs.count) % tabs.count
        return activatingTab(tabs[nextIndex].id)
    }

    public func focusingPane(_ id: PaneID) -> WorkspaceView? {
        guard let activeTabID, let index = tabs.firstIndex(where: { $0.id == activeTabID }),
              tabs[index].tree.leafIDs.contains(id) else { return nil }
        var next = self
        next.tabs[index].focusedPaneID = id
        if next.tabs[index].zoomedPaneID != nil { next.tabs[index].zoomedPaneID = id }
        return next
    }

    /// Replaces one tab's tree after a layout-only change such as resize
    /// mode. The leaf set must be identical; splits and ratios may change.
    public func settingTree(_ tree: PaneTree, for tabID: TabID) -> WorkspaceView? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              Set(tree.leafIDs) == Set(tabs[index].tree.leafIDs) else { return nil }
        var next = self
        next.tabs[index].tree = tree
        guard next.validate().isEmpty else { return nil }
        return next
    }

    public func togglingZoom() -> WorkspaceView? {
        guard let activeTabID, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return nil }
        var next = self
        next.tabs[index].zoomedPaneID = next.tabs[index].zoomedPaneID == nil
            ? next.tabs[index].focusedPaneID : nil
        return next
    }

    public func updatingPane(_ pane: WorkspacePane) -> WorkspaceView? {
        guard panes[pane.id] != nil else { return nil }
        if let runtime = pane.binding?.runtime,
           panes.values.contains(where: { $0.id != pane.id && $0.binding?.runtime == runtime }) {
            return nil
        }
        var next = self
        next.panes[pane.id] = pane
        return next
    }
}
