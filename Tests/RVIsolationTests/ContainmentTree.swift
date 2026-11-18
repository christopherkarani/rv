import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Temp `root/repo/ws` + sibling used by Seatbelt, Landlock, and conformance.
struct ContainmentTree {
    let rootURL: URL
    let workspaceURL: URL
    let siblingURL: URL
    let repositoryURL: URL
    let contained: IsolationPlan
    let observed: IsolationPlan
    let containedDifferingRoot: IsolationPlan

    init() throws {
        // Rooted at the shared system temp, NOT the per-user temp: the
        // per-user temp dir is sanctioned tool-temp (SwiftBuild backend
        // tasks fall back to it), so outside-fence probes must live where
        // the fence actually holds. `/tmp` exists on macOS and Linux.
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("rv-containment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        let workspace = repository.appendingPathComponent("ws", isDirectory: true)
        let sibling = root.appendingPathComponent("sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        rootURL = root.resolvingSymlinksInPath()
        workspaceURL = workspace.resolvingSymlinksInPath()
        siblingURL = sibling.resolvingSymlinksInPath()
        repositoryURL = repository.resolvingSymlinksInPath()

        let workspaceDir = try Self.requireWorkspace(workspaceURL.path)
        let repoRoot = try Self.requireRepositoryRoot(repositoryURL.path)
        contained = try Self.requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspaceDir)
        )
        observed = try Self.requirePlan(
            IsolationCompileRequest(requested: .observed, workspace: workspaceDir)
        )
        containedDifferingRoot = try Self.requirePlan(
            IsolationCompileRequest(
                requested: .contained,
                workspace: workspaceDir,
                repositoryRoot: repoRoot
            )
        )
    }

    func tearDown() {
        #if os(macOS)
        Self.detachWorkspaceImages(under: rootURL.path)
        #endif
        try? FileManager.default.removeItem(at: rootURL)
    }

    static func requireWorkspace(_ path: String) throws -> WorkingDirectory {
        try #require(WorkingDirectory(validating: path))
    }

    static func requireRepositoryRoot(_ path: String) throws -> RepositoryRoot {
        try #require(RepositoryRoot(validating: path))
    }

    func containedPlan() throws -> ContainedPlan {
        compileContainedPlan(workspace: try #require(contained.workspace))
    }

    static func requirePlan(_ request: IsolationCompileRequest) throws -> IsolationPlan {
        switch compileIsolationPlan(request) {
        case .success(let plan):
            return plan
        case .failure(let error):
            switch error {
            case .containedRequiresWorkspace:
                Issue.record("containment fixture compile must not fail containedRequiresWorkspace")
                throw error
            case .notContainedRequest:
                Issue.record("containment fixture compile must not fail notContainedRequest")
                throw error
            }
        }
    }

    func requireContainedIsolation() throws -> ContainedIsolation {
        switch contained.containedIsolation() {
        case .success(let isolation):
            return isolation
        case .failure(let error):
            switch error {
            case .notContained:
                Issue.record("contained fixture must narrow")
            case .missingWorkspace:
                Issue.record("contained fixture must include a workspace")
            case .guaranteesMismatch:
                Issue.record("contained fixture guarantees must match the first slice")
            }
            throw error
        }
    }
}

#if os(macOS)
extension ContainmentTree {
    /// A failed close keeps its disk attached for rv's next-start recovery,
    /// which tests never run. Detach and delete what this tree still holds;
    /// images mounted under other trees are left alone.
    static func detachWorkspaceImages(under root: String) {
        for image in attachedWorkspaceImages(under: root) {
            guard let device = image.device else { continue }
            let detached = detachWorkspaceDisk(device, mountPoint: image.mountPoint)
            unlinkImageIfDetached(image.imagePath, detachSucceeded: detached)
        }
    }

    /// rv workspace images mounted at or below `root`.
    static func attachedWorkspaceImages(under root: String) -> [AttachedWorkspaceImage] {
        // The kernel reports `/private/tmp/…`; `URL` paths may say `/tmp/…`.
        let roots = Set([root, realpath(root, nil).map { resolved in
            defer { free(resolved) }
            return String(cString: resolved)
        } ?? root])
        func isUnderRoot(_ mountPoint: String) -> Bool {
            roots.contains { mountPoint == $0 || mountPoint.hasPrefix($0 + "/") }
        }
        // Only mounted images match, so the cheap kernel table rules out the
        // common case (nothing left) without running `hdiutil`.
        let mounts = WorkspaceHosts.mountTable()
        guard mounts.values.contains(where: isUnderRoot),
            let info = boundedHdiutilInfo()
        else { return [] }
        let images = AttachedWorkspaceImage.parse(hdiutilInfo: info, mounts: mounts) ?? []
        return images.filter { image in
            image.mountPoint.map(isUnderRoot) ?? false
        }
    }

    /// `hdiutil info -plist` through `runTool`, so it takes the same
    /// one-helper-at-a-time lock as rv's own attach, mount, and detach
    /// instead of piling onto diskimagesd while another test attaches.
    /// Bounded: DiskArbitration can wedge.
    private static func boundedHdiutilInfo(timeout: TimeInterval = 30) -> Data? {
        let info = runTool(["/usr/bin/hdiutil", "info", "-plist"], deadline: timeout)
        guard info.status == 0, info.timedOut == false, info.helperStillAlive == false else {
            return nil
        }
        return Data(info.stdout.utf8)
    }
}
#endif
