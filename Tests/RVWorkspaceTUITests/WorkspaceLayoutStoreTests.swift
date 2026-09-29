#if os(macOS)
import Foundation
import Darwin
import Testing
import RVDomain
@testable import RVWorkspaceTUI

private func layoutFixture() throws -> (URL, URL) {
    let temporary = FileManager.default.temporaryDirectory.path
    guard let canonicalTemporary = realpath(temporary, nil) else {
        throw WorkspaceLayoutStoreError.invalidProject
    }
    defer { free(canonicalTemporary) }
    let root = URL(fileURLWithPath: String(cString: canonicalTemporary))
        .appendingPathComponent("rv-layout-test-\(UUID().uuidString)")
    let config = root.appendingPathComponent("config")
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    return (root, project)
}

@Test func unsavedBusyPrimaryGivesSecondaryAnUnsavedBootstrapView() throws {
    let (root, project) = try layoutFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config")
    let primary = try WorkspaceLayoutStore.open(
        canonicalOriginalProject: project.path, configurationDirectory: config
    ).session
    #expect(primary.revision == 0)
    let secondary = try WorkspaceLayoutStore.open(
        canonicalOriginalProject: project.path, configurationDirectory: config
    ).session
    #expect(!secondary.isPrimary)
    #expect(secondary.revision == 0)
    #expect(secondary.view.tabs.isEmpty)
    #expect(secondary.viewID != primary.viewID)
}

@Test func openTightensSiblingCreatedSubtreePermissions() throws {
    // The workspace host creates the shared config root with default
    // permissions before the TUI opens its layout; open must tighten the
    // owned subtree instead of refusing a fresh HOME.
    let (root, project) = try layoutFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config")
    let layouts = config.appendingPathComponent("workspace-layouts")
    try FileManager.default.createDirectory(
        at: layouts, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
    )
    let session = try WorkspaceLayoutStore.open(
        canonicalOriginalProject: project.path, configurationDirectory: config
    ).session
    #expect(session.revision == 0)
    let mode = try FileManager.default.attributesOfItem(
        atPath: layouts.path
    )[.posixPermissions] as? Int
    #expect(mode == 0o700)
}

@Test func layoutSavePumpCommitsInitialViewWithStoreIdentityBeforeDetach() throws {
    let (root, project) = try layoutFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = try WorkspaceLayoutStore.open(
        canonicalOriginalProject: project.path,
        configurationDirectory: root.appendingPathComponent("config")
    ).session
    let session = FakeWorkspaceSession()
    let model = WorkspaceTUIModel(
        session: session,
        summary: session.summary,
        launcher: [RuntimeLaunchChoice(id: "shell", title: "shell",
                                       executable: "/bin/sh", arguments: [], hook: nil)],
        initialViewID: layout.viewID
    )
    let savePump = WorkspaceLayoutSavePump(model: model, layout: layout) { _ in }
    savePump.start()
    #expect(savePump.stop() == nil)
    #expect(layout.revision == 1)
    #expect(layout.view.id == layout.viewID)
    #expect(layout.view == model.snapshotView())
}

@Test func layoutStoreRoundTripsIDsBindingsAndStructuralState() throws {
    let (root, project) = try layoutFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let opened = try WorkspaceLayoutStore.open(canonicalOriginalProject: project.path,
                                                configurationDirectory: root.appendingPathComponent("config"))
    #expect(opened.notice == nil)
    #expect(opened.session.isPrimary)
    let pane = PaneID()
    let binding = RuntimeBinding(workspace: WorkspaceSessionID(), runtime: RuntimeSessionID(), generation: 42)
    let view = WorkspaceView(id: opened.session.viewID, tabs: [
        WorkspaceTab(id: TabID(), userTitle: "Work", tree: .leaf(pane), focusedPaneID: pane,
                     zoomedPaneID: pane),
    ], activeTabID: nil, panes: [:])
    let tab = view.tabs[0]
    let valid = WorkspaceView(id: opened.session.viewID, tabs: [tab], activeTabID: tab.id,
                              panes: [pane: WorkspacePane(id: pane, userTitle: "Editor",
                                                          binding: binding, lifecycle: .running)])
    try opened.session.save(valid)
    #expect(opened.session.revision == 1)
    let second = try WorkspaceLayoutStore.open(canonicalOriginalProject: project.path,
                                                configurationDirectory: root.appendingPathComponent("config"))
    #expect(second.session.isPrimary == false)
    #expect(second.session.viewID != opened.session.viewID)
    #expect(second.session.view.tabs.map(\.id) == valid.tabs.map(\.id))
    #expect(second.session.view.tabs[0].zoomedPaneID == nil)
    #expect(second.session.view.panes[pane]?.binding?.workspace == binding.workspace)
    #expect(second.session.view.panes[pane]?.binding?.runtime == binding.runtime)
    #expect(second.session.view.panes[pane]?.binding?.generation == 0)
    #expect(second.session.view.panes[pane]?.lifecycle == .disconnected)
    try second.session.save(second.session.view)
    let snapshots = try FileManager.default.contentsOfDirectory(at: second.session.directoryURL,
                                                                  includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
    #expect(snapshots.count == 2)
    #expect(snapshots.allSatisfy {
        ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions]) as? Int ?? 0) & 0o077 == 0
    })
}

@Test func layoutStoreRejectsInvalidViewBeforeReplacingCommittedSnapshot() throws {
    let (root, project) = try layoutFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try WorkspaceLayoutStore.open(canonicalOriginalProject: project.path,
                                                configurationDirectory: root.appendingPathComponent("config")).session
    let pane = PaneID()
    let tab = WorkspaceTab(id: TabID(), tree: .leaf(pane), focusedPaneID: pane)
    let valid = WorkspaceView(id: session.viewID, tabs: [tab], activeTabID: tab.id,
                              panes: [pane: WorkspacePane(id: pane)])
    try session.save(valid)
    let invalid = WorkspaceView(id: session.viewID, tabs: [tab], activeTabID: tab.id, panes: [:])
    #expect(throws: WorkspaceLayoutStoreError.invalidView) { try session.save(invalid) }
    #expect(session.revision == 1)
    #expect(session.view == valid)
}

@Test func corruptAndNewerPrimaryDocumentsOpenTemporaryViewsWithoutOverwrite() throws {
    let (root, project) = try layoutFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config")
    let primaryID: ViewID
    let primaryURL: URL
    do {
        let primary = try WorkspaceLayoutStore.open(canonicalOriginalProject: project.path,
                                                    configurationDirectory: config).session
        primaryID = primary.viewID
        primaryURL = primary.directoryURL.appendingPathComponent("\(primaryID.rawValue.uuidString).json")
        try primary.save(primary.view)
    }
    try Data("not json".utf8).write(to: primaryURL)
    let corrupt = try WorkspaceLayoutStore.open(canonicalOriginalProject: project.path,
                                                configurationDirectory: config)
    #expect(corrupt.notice == .corrupt)
    #expect(corrupt.session.isPrimary == false)
    #expect(corrupt.session.viewID != primaryID)
    try corrupt.session.save(corrupt.session.view)
    #expect(try String(contentsOf: primaryURL, encoding: .utf8) == "not json")
    let bytes = try JSONSerialization.data(withJSONObject: ["version": 999])
    try bytes.write(to: primaryURL)
    let newer = try WorkspaceLayoutStore.open(canonicalOriginalProject: project.path,
                                              configurationDirectory: config)
    #expect(newer.notice == .newerVersion(999))
    #expect(newer.session.isPrimary == false)
    try newer.session.save(newer.session.view)
    #expect(try Data(contentsOf: primaryURL) == bytes)
}

@Test func layoutStoreRejectsNoncanonicalProjectAndUnsafeConfigRoot() throws {
    let (root, project) = try layoutFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config")
    #expect(throws: WorkspaceLayoutStoreError.invalidProject) {
        _ = try WorkspaceLayoutStore.open(canonicalOriginalProject: project.path + "/.", configurationDirectory: config)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: config.path)
    #expect(throws: WorkspaceLayoutStoreError.unsafeDirectory) {
        _ = try WorkspaceLayoutStore.open(canonicalOriginalProject: project.path, configurationDirectory: config)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: config.path)
    _ = try WorkspaceLayoutStore.open(canonicalOriginalProject: project.path, configurationDirectory: config)
    let layouts = config.appendingPathComponent("workspace-layouts")
    // Owned, non-other-writable drift (e.g. a sibling tool's defaults) is
    // repaired to 0700 so a fresh install opens; other-writable still fails
    // closed above.
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layouts.path)
    _ = try WorkspaceLayoutStore.open(canonicalOriginalProject: project.path, configurationDirectory: config)
    let repaired = try FileManager.default.attributesOfItem(
        atPath: layouts.path
    )[.posixPermissions] as? Int
    #expect(repaired == 0o700)
}

@Test func fifoAtSnapshotPathIsReportedCorruptWithoutBlocking() throws {
    let (root, project) = try layoutFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config")
    let snapshot: URL
    do {
        let session = try WorkspaceLayoutStore.open(canonicalOriginalProject: project.path,
                                                    configurationDirectory: config).session
        snapshot = session.directoryURL.appendingPathComponent("\(session.viewID.rawValue.uuidString).json")
    }
    #expect(mkfifo(snapshot.path, 0o600) == 0)
    let reopened = try WorkspaceLayoutStore.open(canonicalOriginalProject: project.path,
                                                 configurationDirectory: config)
    #expect(reopened.notice == .corrupt)
    #expect(reopened.session.isPrimary == false)
}

@Test func uncertainCommitRequiresReopenAndReconcilesVisibleRevision() throws {
    let (root, project) = try layoutFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config")
    let snapshot: URL
    do {
        let session = try WorkspaceLayoutStore.openForTesting(
            canonicalOriginalProject: project.path, configurationDirectory: config,
            failDirectorySyncAfterRename: true).session
        snapshot = session.directoryURL.appendingPathComponent("\(session.viewID.rawValue.uuidString).json")
        #expect(throws: WorkspaceLayoutStoreError.commitUncertain(session.viewID)) {
            try session.save(session.view)
        }
        #expect(session.requiresReopen)
        #expect(session.revision == 0)
        #expect(throws: WorkspaceLayoutStoreError.requiresReopen) {
            try session.save(session.view)
        }
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
    }
    let reopened = try WorkspaceLayoutStore.open(canonicalOriginalProject: project.path,
                                                 configurationDirectory: config)
    #expect(reopened.notice == nil)
    #expect(reopened.session.isPrimary)
    #expect(reopened.session.revision == 1)
    try reopened.session.save(reopened.session.view)
    #expect(reopened.session.revision == 2)
}
#endif
