#if os(macOS)
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// A workspace whose close fails keeps its disk attached on purpose: rv
/// recovers it on the next start. Tests never run that recovery, so the
/// fixture must detach what its own tree left behind, or every failed
/// close under load leaks a mounted image and a diskimages-helper.
@Suite("Containment fixture teardown", .serialized)
struct ContainmentTreeTeardownTests {
    @Test func tearDownDetachesAWorkspaceThatNeverClosed() throws {
        let tree = try ContainmentTree()
        let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        let supervisor = try WorkspaceSessionSupervisor.open(
            directory,
            lifecycleLog: .file(tree.rootURL.appendingPathComponent("workspace.jsonl")),
            runtimeLog: tree.rootURL.appendingPathComponent("runtimes.jsonl"),
            instanceJournal: .file(tree.rootURL.appendingPathComponent("instances.jsonl")),
            reviewConfigDirectory: nil
        ).get()
        let attached = ContainmentTree.attachedWorkspaceImages(under: tree.rootURL.path)
        let image = try #require(attached.first, "open must mount an rv image under the tree")

        // The owner is still alive and never closed, as after a failed close.
        withExtendedLifetime(supervisor) {
            tree.tearDown()
        }

        #expect(ContainmentTree.attachedWorkspaceImages(under: tree.rootURL.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: image.imagePath))
        #expect(!FileManager.default.fileExists(atPath: tree.rootURL.path))
    }

    @Test func tearDownLeavesOtherTreesMounted() throws {
        let other = try ContainmentTree()
        defer { other.tearDown() }
        let directory = try #require(WorkingDirectory(validating: other.workspaceURL.path))
        let supervisor = try WorkspaceSessionSupervisor.open(
            directory,
            lifecycleLog: .file(other.rootURL.appendingPathComponent("workspace.jsonl")),
            runtimeLog: other.rootURL.appendingPathComponent("runtimes.jsonl"),
            instanceJournal: .file(other.rootURL.appendingPathComponent("instances.jsonl")),
            reviewConfigDirectory: nil
        ).get()
        defer { _ = supervisor.close() }

        let tree = try ContainmentTree()
        tree.tearDown()

        #expect(ContainmentTree.attachedWorkspaceImages(under: other.rootURL.path).count == 1)
    }
}
#endif
