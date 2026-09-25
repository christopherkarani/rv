#if os(macOS)
import Foundation
import RVDomain
import Testing
@testable import RVIsolation
@testable import RVWorkspaceTUI

@Suite(.serialized)
struct WorkspaceTUIIntegrationTests {
@Test func emptyWorkspaceStartsAnInteractiveContainedShell() throws {
    let host = try OpenedHost()
    defer { host.close() }
    let session = try LiveWorkspaceTUISession.connect(host.server.endpoint).get()
    let probe = try WorkspaceClient.connect(host.server.endpoint).get()
    let script = "stty icanon icrnl; printf 'RV-AUTO-SHELL-READY\\r\\n'; while IFS= read -r line; do if [ \"$line\" = quit ]; then break; else printf 'RV-AUTO-SHELL-REPLY:%s\\r\\n' \"$line\"; fi; done"
    let model = WorkspaceTUIModel(
        session: session,
        summary: try session.inventory().get().summary,
        launcher: [RuntimeLaunchChoice(
            id: "shell", title: "shell", executable: "/bin/sh",
            arguments: ["-c", script], hook: nil
        )],
        rows: 12,
        columns: 40
    )
    try model.connect().get()
    model.startEventDelivery()
    defer {
        model.detachSession()
    }

    model.launchDefaultRuntimeIfEmpty()

    #expect(model.snapshot().terminal?.lease == .owned)
    let runtime = try #require(model.snapshot().terminal?.runtime)
    send("typed input", to: model)
    #expect(waitUntil { screen(model).contains("RV-AUTO-SHELL-READY") })
    #expect(waitUntil { screen(model).contains("RV-AUTO-SHELL-REPLY:typed input") })

    send("quit", to: model)
    #expect(waitUntil { model.snapshot().mode == .launcher })
    #expect(model.snapshot().terminal?.running == false)
    #expect(model.snapshot().terminal?.runtime == runtime)
    model.handle(.character("1"))
    #expect(waitUntil {
        model.snapshot().terminal?.runtime != runtime && model.snapshot().terminal?.lease == .owned
    })
    #expect(waitUntil { screen(model).contains("RV-AUTO-SHELL-READY") })
    send("again", to: model)
    #expect(waitUntil { screen(model).contains("RV-AUTO-SHELL-REPLY:again") })
    #expect(try probe.listRuntimes().get().first { $0.runtime == runtime }?.running == false)
    #expect(try session.inventory().get().summary.phase == "active")
}

@Test func hostPTYBytesResizeDetachAndReattachUseTheSameRuntime() throws {
    let host = try OpenedHost()
    defer { host.close() }
    let session = try LiveWorkspaceTUISession.connect(host.server.endpoint).get()
    let probe = try WorkspaceClient.connect(host.server.endpoint).get()
    let summary = try session.inventory().get().summary
    let script = "stty icanon icrnl; printf 'RV-TUI-MARKER\\r\\n'; while IFS= read -r line; do if [ \"$line\" = size ]; then stty size; else printf 'REPLY:%s\\r\\n' \"$line\"; fi; done"
    let shell = WorkspaceTUIModel(
        session: session,
        summary: summary,
        launcher: [RuntimeLaunchChoice(
            id: "shell", title: "shell", executable: "/bin/sh",
            arguments: ["-c", script], hook: nil
        )],
        rows: 24,
        columns: 80
    )
    try shell.connect().get()
    defer {
        shell.detachSession()
    }
    shell.startEventDelivery()
    shell.handle(.character("1"))
    #expect(waitUntil { shell.snapshot().terminal?.lease == .owned })
    let runtime = try #require(shell.snapshot().terminal?.runtime)

    #expect(shell.snapshot().terminal?.lease == .owned)
    #expect(try probe.listRuntimes().get().first?.inputOwner == true)
    #expect(waitUntil { screen(shell).contains("RV-TUI-MARKER") })
    send("Z", to: shell)
    #expect(waitUntil { screen(shell).contains("REPLY:Z") })

    let resizeAt = Date(timeIntervalSince1970: 1_000)
    shell.noteSize(rows: 17, columns: 53, now: resizeAt)
    shell.processPendingWork(now: resizeAt.addingTimeInterval(0.1))
    send("size", to: shell)
    #expect(waitUntil { screen(shell).contains("17 53") })
    #expect(shell.terminalSize()?.rows == 17)
    #expect(shell.terminalSize()?.columns == 53)

    shell.detachSession()
    let reattachClient = try WorkspaceClient.connect(host.server.endpoint).get()
    let remaining = try reattachClient.listRuntimes().get()
    #expect(remaining.contains { $0.runtime == runtime && $0.running })

    let second = try LiveWorkspaceTUISession.connect(host.server.endpoint).get()
    let reattached = WorkspaceTUIModel(session: second, summary: try second.inventory().get().summary, launcher: [])
    try reattached.connect().get()
    #expect(reattached.snapshot().terminal?.runtime == runtime)
    reattached.startEventDelivery()
    defer {
        reattached.detachSession()
    }
    #expect(waitUntil { screen(reattached).contains("RV-TUI-MARKER") })
    #expect(reattached.snapshot().terminal?.running == true)
    #expect(try reattachClient.listRuntimes().get().filter(\.terminal).count == 1)
    _ = reattachClient.cancelRuntime(runtime)
}

@Test func sustainedPTYOutputKeepsInputResponsiveAndReachesTheFinalScreen() throws {
    let host = try OpenedHost()
    defer { host.close() }
    let session = try LiveWorkspaceTUISession.connect(host.server.endpoint).get()
    let script = "stty icanon icrnl;read g;(i=0;while ((i<1000));do printf 'OUT:%d:abcdefghijklmnopqrstuvwx\\r\\n' \"$i\";((i==400))&&echo READY;if ((i>400));then sleep .05;fi;((i++));done)&p=$!;read -r l;printf 'IN:%s\\r\\n' \"$l\";kill $p;wait $p;printf 'DONE\\r\\n'"
    // The kill/notice/DONE cascade lands within one screen poll, so the
    // screen must be tall enough to retain IN:stop past bash's multi-line
    // job-termination notice.
    let shell = WorkspaceTUIModel(
        session: session,
        summary: try session.inventory().get().summary,
        launcher: [RuntimeLaunchChoice(
            id: "shell", title: "shell", executable: "/bin/bash",
            arguments: ["-c", script], hook: nil
        )],
        rows: 21,
        columns: 78
    )
    try shell.connect().get()
    shell.startEventDelivery()
    defer {
        shell.detachSession()
    }
    shell.handle(.character("1"))
    #expect(waitUntil { shell.snapshot().terminal?.lease == .owned })
    send("go", to: shell)
    #expect(waitUntil(seconds: 8) { screen(shell).contains("READY") })
    #expect(shell.snapshot().terminal?.overflowed == false)
    let sendBegan = Date()
    send("stop", to: shell)
    #expect(Date().timeIntervalSince(sendBegan) < 3)
    #expect(waitUntil(seconds: 8) { screen(shell).contains("IN:stop") })
    #expect(waitUntil(seconds: 8) { screen(shell).contains("DONE") })
    #expect(shell.snapshot().terminal?.overflowed == false)
    #expect(TerminalScrollback.lines == 1_000)
}

@Test func externalInputLeaseKeepsTheTUIReadOnlyUntilTheLeaseIsReleased() throws {
    let host = try OpenedHost()
    defer { host.close() }
    let owner = try WorkspaceClient.connect(host.server.endpoint).get()
    let runtime = try owner.launchRuntime(
        executable: "/bin/sh",
        arguments: ["-c", "stty icanon icrnl; while IFS= read -r line; do printf 'OWNER:%s\\r\\n' \"$line\"; done"],
        terminalRows: 12,
        terminalColumns: 40
    ).get()
    try owner.subscribeTerminal(runtime.runtime).get()
    try owner.acquireTerminalInput(runtime.runtime).get()

    let viewer = try WorkspaceClient.connect(host.server.endpoint).get()
    let session = try LiveWorkspaceTUISession.connect(host.server.endpoint).get()
    let model = WorkspaceTUIModel(session: session, summary: try session.inventory().get().summary, launcher: [])
    try model.connect().get()
    #expect(model.snapshot().terminal?.runtime == runtime.runtime)
    #expect(model.snapshot().terminal?.lease == .readOnly)
    model.apply([.inputOwner(runtime: runtime.runtime, owned: true)])
    #expect(model.snapshot().terminal?.lease == .readOnly)

    model.handle(.character("X"))
    #expect(try viewer.listRuntimes().get().first?.inputOwner == true)
    try owner.releaseTerminalInput(runtime.runtime).get()
    model.apply([.inputOwner(runtime: runtime.runtime, owned: false)])
    model.processPendingWork()
    #expect(waitUntil { model.snapshot().terminal?.lease == .owned })
    #expect(try viewer.listRuntimes().get().first?.inputOwner == true)
    model.detachSession()
    _ = owner.cancelRuntime(runtime.runtime)
}

private func screen(_ model: WorkspaceTUIModel) -> String {
    guard let frame = model.terminalFrame() else { return "" }
    return (0..<frame.rows).map(frame.line).joined(separator: "\n")
}

private func send(_ string: String, to model: WorkspaceTUIModel) {
    for character in string { model.handle(.character(character)) }
    model.handle(.enter)
}

private struct OpenedHost {
    var supervisor: WorkspaceSessionSupervisor
    var server: WorkspaceHostServer
    var root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rv-tui-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspace = root.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let directory = try #require(WorkingDirectory(validating: workspace.path))
        supervisor = try WorkspaceSessionSupervisor.open(
            directory,
            lifecycleLog: .file(config.appendingPathComponent("workspace-sessions.jsonl"))
        ).get()
        server = try WorkspaceHostServer.start(
            supervisor: supervisor,
            configurationDirectory: config,
            sessionStore: .file(config.appendingPathComponent("runtime-sessions.jsonl"))
        ).get()
    }

    func close() {
        server.stop()
        _ = supervisor.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private func waitUntil(seconds: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return false
}
}
#endif
