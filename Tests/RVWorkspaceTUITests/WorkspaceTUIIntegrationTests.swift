#if os(macOS)
import Foundation
import RVDomain
import Testing
@testable import RVIsolation
@testable import RVWorkspaceTUI

@Suite(.serialized)
struct WorkspaceTUIIntegrationTests {
@Test func hostPTYBytesResizeDetachAndReattachUseTheSameRuntime() throws {
    let host = try OpenedHost()
    defer { host.close() }
    let client = try WorkspaceClient.connect(host.server.endpoint).get()
    let terminalClient = try WorkspaceClient.connect(host.server.endpoint).get()
    let live = LiveWorkspaceTUIClient(controlClient: client, terminalClient: terminalClient)
    let summary = try live.describe().get()
    let script = "stty icanon icrnl; printf 'RV-TUI-MARKER\\r\\n'; while IFS= read -r line; do if [ \"$line\" = size ]; then stty size; else printf 'REPLY:%s\\r\\n' \"$line\"; fi; done"
    let shell = WorkspaceTUIModel(
        client: live,
        summary: summary,
        launcher: [RuntimeLaunchChoice(
            id: "shell", title: "shell", executable: "/bin/sh",
            arguments: ["-c", script], hook: nil
        )],
        rows: 24,
        columns: 80
    )
    try shell.connect().get()
    var pump: TerminalEventPump? = TerminalEventPump(client: live, model: shell)
    defer {
        pump?.stop()
        shell.detachSession()
    }
    pump?.start()
    shell.handle(.control("g"))
    shell.handle(.character("n"))
    shell.handle(.character("1"))
    #expect(waitUntil { shell.snapshot().panes.values.first?.lease == .owned })
    let pane = try #require(shell.snapshot().focused)
    let runtime = try #require(shell.snapshot().panes[pane]?.runtime)

    #expect(shell.snapshot().panes[pane]?.lease == .owned)
    #expect(try client.listRuntimes().get().first?.inputOwner == true)
    #expect(waitUntil { screen(shell, pane).contains("RV-TUI-MARKER") })
    send("Z", to: shell)
    #expect(waitUntil { screen(shell, pane).contains("REPLY:Z") })

    let resizeAt = Date(timeIntervalSince1970: 1_000)
    shell.noteSize(of: pane, rows: 17, columns: 53, now: resizeAt)
    shell.processPendingWork(now: resizeAt.addingTimeInterval(0.1))
    send("size", to: shell)
    #expect(waitUntil { screen(shell, pane).contains("17 53") })
    #expect(shell.terminalSize(for: pane)?.rows == 17)
    #expect(shell.terminalSize(for: pane)?.columns == 53)

    pump?.stop()
    pump = nil
    shell.detachSession()
    let reattachClient = try WorkspaceClient.connect(host.server.endpoint).get()
    let remaining = try reattachClient.listRuntimes().get()
    #expect(remaining.contains { $0.runtime == runtime && $0.running })

    let reattachTerminalClient = try WorkspaceClient.connect(host.server.endpoint).get()
    let second = LiveWorkspaceTUIClient(
        controlClient: reattachClient,
        terminalClient: reattachTerminalClient
    )
    let reattached = WorkspaceTUIModel(client: second, summary: try second.describe().get(), launcher: [])
    try reattached.connect().get()
    let reattachedPane = try #require(
        reattached.snapshot().panes.first { $0.value.runtime == runtime }?.key
    )
    let replay = TerminalEventPump(client: second, model: reattached)
    pump = replay
    replay.start()
    #expect(waitUntil { screen(reattached, reattachedPane).contains("RV-TUI-MARKER") })
    #expect(reattached.snapshot().panes[reattachedPane]?.running == true)
    #expect(try reattachClient.listRuntimes().get().filter(\.terminal).count == 1)
    _ = reattachClient.cancelRuntime(runtime)
}

@Test func focusedInputAndPaneCloseLeaveTheSiblingRuntimeAlive() throws {
    let host = try OpenedHost()
    defer { host.close() }
    let client = try WorkspaceClient.connect(host.server.endpoint).get()
    let terminalClient = try WorkspaceClient.connect(host.server.endpoint).get()
    let live = LiveWorkspaceTUIClient(controlClient: client, terminalClient: terminalClient)
    let shell = WorkspaceTUIModel(
        client: live,
        summary: try live.describe().get(),
        launcher: [RuntimeLaunchChoice(
            id: "shell", title: "shell", executable: "/bin/sh",
            arguments: ["-c", "stty icanon icrnl; while IFS= read -r line; do printf 'RECEIVED:%s\\r\\n' \"$line\"; done"],
            hook: nil
        )],
        rows: 12,
        columns: 40
    )
    try shell.connect().get()
    let pump = TerminalEventPump(client: live, model: shell)
    pump.start()
    defer {
        pump.stop()
        shell.detachSession()
    }
    shell.handle(.control("g"))
    shell.handle(.character("n"))
    shell.handle(.character("1"))
    #expect(waitUntil { shell.snapshot().panes.values.first?.lease == .owned })
    let firstPane = try #require(shell.snapshot().focused)
    let firstRuntime = try #require(shell.snapshot().panes[firstPane]?.runtime)
    #expect(shell.snapshot().panes[firstPane]?.lease == .owned)
    #expect(waitUntil { shell.snapshot().panes[firstPane]?.subscribed == true })

    shell.noteCanvas(width: 80, height: 24)
    shell.handle(.control("g"))
    shell.handle(.character("v"))
    #expect(waitUntil { shell.snapshot().panes.count == 2 })
    let secondPane = try #require(shell.snapshot().focused)
    let secondRuntime = try #require(shell.snapshot().panes[secondPane]?.runtime)
    #expect(firstRuntime != secondRuntime)
    #expect(waitUntil { shell.snapshot().panes[secondPane]?.subscribed == true })

    shell.handle(.control("g"))
    shell.handle(.character("h"))
    #expect(waitUntil { shell.snapshot().focused == firstPane })
    #expect(waitUntil { shell.snapshot().panes[firstPane]?.lease == .owned })
    send("A", to: shell)
    #expect(waitUntil { screen(shell, firstPane).contains("RECEIVED:A") })
    #expect(screen(shell, secondPane).contains("RECEIVED:A") == false)

    shell.handle(.control("g"))
    shell.handle(.character("l"))
    #expect(waitUntil { shell.snapshot().focused == secondPane })
    #expect(waitUntil { shell.snapshot().panes[secondPane]?.lease == .owned })
    send("B", to: shell)
    #expect(waitUntil { screen(shell, secondPane).contains("RECEIVED:B") })
    #expect(screen(shell, firstPane).contains("RECEIVED:B") == false)

    shell.handle(.control("g"))
    shell.handle(.character("h"))
    shell.handle(.control("g"))
    shell.handle(.character("x"))
    #expect(waitUntil { shell.snapshot().panes[firstPane] == nil })
    #expect(shell.snapshot().panes[firstPane] == nil)
    #expect(shell.snapshot().panes[secondPane]?.running == true)
    #expect(try live.describe().get().phase == "active")
    let runtimes = try live.listRuntimes().get()
    #expect(runtimes.contains { $0.id == secondRuntime && $0.running })
    #expect(runtimes.contains { $0.id == firstRuntime && $0.running == false })
}

@Test func sustainedPTYOutputKeepsInputResponsiveAndReachesTheFinalScreen() throws {
    let host = try OpenedHost()
    defer { host.close() }
    let client = try WorkspaceClient.connect(host.server.endpoint).get()
    let terminalClient = try WorkspaceClient.connect(host.server.endpoint).get()
    let live = LiveWorkspaceTUIClient(controlClient: client, terminalClient: terminalClient)
    let script = "stty icanon icrnl;read g;(i=0;while ((i<1000));do printf 'OUT:%d:abcdefghijklmnopqrstuvwx\\r\\n' \"$i\";((i==400))&&echo READY;if ((i>400));then sleep .05;fi;((i++));done)&p=$!;read -r l;printf 'IN:%s\\r\\n' \"$l\";kill $p;wait $p;printf 'DONE\\r\\n'"
    let shell = WorkspaceTUIModel(
        client: live,
        summary: try live.describe().get(),
        launcher: [RuntimeLaunchChoice(
            id: "shell", title: "shell", executable: "/bin/bash",
            arguments: ["-c", script], hook: nil
        )],
        rows: 12,
        columns: 40
    )
    try shell.connect().get()
    let pump = TerminalEventPump(client: live, model: shell)
    pump.start()
    defer {
        pump.stop()
        shell.detachSession()
    }
    shell.handle(.control("g"))
    shell.handle(.character("n"))
    shell.handle(.character("1"))
    #expect(waitUntil { shell.snapshot().panes.values.first?.lease == .owned })
    let pane = try #require(shell.snapshot().focused)
    #expect(shell.snapshot().panes[pane]?.lease == .owned)
    send("go", to: shell)
    #expect(waitUntil(seconds: 8) { screen(shell, pane).contains("READY") })
    #expect(shell.snapshot().panes[pane]?.overflowed == false)
    let sendBegan = Date()
    send("stop", to: shell)
    #expect(Date().timeIntervalSince(sendBegan) < 3)
    #expect(waitUntil(seconds: 8) { screen(shell, pane).contains("IN:stop") })
    #expect(waitUntil(seconds: 8) { screen(shell, pane).contains("DONE") })
    #expect(shell.snapshot().panes[pane]?.overflowed == false)
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
    let viewerTerminal = try WorkspaceClient.connect(host.server.endpoint).get()
    let live = LiveWorkspaceTUIClient(controlClient: viewer, terminalClient: viewerTerminal)
    let model = WorkspaceTUIModel(client: live, summary: try live.describe().get(), launcher: [])
    try model.connect().get()
    let pane = try #require(model.snapshot().focused)
    #expect(model.snapshot().panes[pane]?.lease == .readOnly)
    model.apply([.inputOwner(runtime: runtime.runtime, owned: true)])
    #expect(model.snapshot().panes[pane]?.lease == .readOnly)

    model.handle(.character("X"))
    #expect(try viewer.listRuntimes().get().first?.inputOwner == true)
    try owner.releaseTerminalInput(runtime.runtime).get()
    model.apply([.inputOwner(runtime: runtime.runtime, owned: false)])
    model.processPendingWork()
    #expect(waitUntil { model.snapshot().panes[pane]?.lease == .owned })
    #expect(try viewer.listRuntimes().get().first?.inputOwner == true)
    model.detachSession()
    _ = owner.cancelRuntime(runtime.runtime)
}

private func screen(_ model: WorkspaceTUIModel, _ pane: PaneID) -> String {
    guard let frame = model.terminalFrame(for: pane) else { return "" }
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
