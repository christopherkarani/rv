#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RVWorkspaceTUI

private func savePumpFixture() throws -> (URL, URL) {
    let temporary = FileManager.default.temporaryDirectory.path
    guard let canonicalTemporary = realpath(temporary, nil) else {
        throw WorkspaceLayoutStoreError.invalidProject
    }
    defer { free(canonicalTemporary) }
    let root = URL(fileURLWithPath: String(cString: canonicalTemporary))
        .appendingPathComponent("rv-save-pump-test-\(UUID().uuidString)")
    let config = root.appendingPathComponent("config")
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    return (root, project)
}

@Test func savePumpSurvivesConcurrentKickAndSaveSync() throws {
    let (root, project) = try savePumpFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config")
    let opened = try WorkspaceLayoutStore.open(
        canonicalOriginalProject: project.path, configurationDirectory: config
    ).session
    let session = FakeWorkspaceSession()
    let model = WorkspaceTUIModel(
        session: session,
        summary: session.summary,
        launcher: [RuntimeLaunchChoice(id: "shell", title: "shell", executable: "/bin/sh",
                                       arguments: [], hook: nil)],
        initialViewID: opened.viewID
    )
    let failures = SaveFailureBox()
    let pump = WorkspaceLayoutSavePump(model: model, layout: opened) { message in
        failures.record(message)
    }
    pump.start()
    let group = DispatchGroup()
    for _ in 0..<4 {
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<50 {
                pump.kick()
                pump.saveSync(model.snapshotView())
            }
            group.leave()
        }
    }
    group.wait()
    #expect(pump.stop() == nil)
    #expect(failures.messages.isEmpty)
    #expect(opened.revision >= 1)
}

private final class SaveFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(message)
    }
}
#endif
