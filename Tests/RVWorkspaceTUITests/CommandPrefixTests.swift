import Foundation
import Testing
@testable import RVWorkspaceTUI

private let target = PrefixTarget(pane: PaneID(), generation: nil)

@Test func prefixConsumesControlBAndUnknownKeys() {
    var mode = CommandMode.terminal
    let entered = CommandPrefix.route(.control("b"), mode: mode, launcher: [], target: target)
    mode = entered.0
    #expect(mode == .prefix(target))
    #expect(entered.1 == nil)
    let unknown = CommandPrefix.route(.character("Q"), mode: mode, launcher: [])
    #expect(unknown == (.terminal, .invalidPrefix))
    let plain = CommandPrefix.route(.control("c"), mode: .terminal, launcher: [])
    #expect(plain.1 == .sendKey(.control("c")))
}

@Test func prefixCommandsDoNotEncodeThePrefix() {
    #expect(CommandPrefix.route(.character("s"), mode: .prefix(target), launcher: []).1 == .invalidPrefix)
    #expect(CommandPrefix.route(.character("q"), mode: .prefix(target), launcher: []).1 == .detach)
    #expect(CommandPrefix.route(.character("?"), mode: .prefix(target), launcher: []).1 == .help)
    #expect(CommandPrefix.route(.control("b"), mode: .prefix(target), launcher: []).1 == .send(Data([0x02])))
    #expect(CommandPrefix.route(.escape, mode: .prefix(target), launcher: []) == (.terminal, nil))
    #expect(CommandPrefix.route(.control("g"), mode: .terminal, launcher: []).1 == .sendKey(.control("g")))
    #expect(CommandPrefix.route(.escape, mode: .help, launcher: []).0 == .terminal)
    #expect(TerminalInputEncoder.bytes(for: .enter) == Data([0x0d]))
    #expect(TerminalInputEncoder.bytes(for: .control("c")) == Data([0x03]))
}

@Test func emptyWorkspaceLaunchNumbersWorkWithoutThePrefix() {
    let shell = RuntimeLaunchChoice(id: "shell", title: "shell", executable: "/bin/sh", arguments: [], hook: nil)
    let opencode = RuntimeLaunchChoice(id: "opencode", title: "opencode", executable: "/bin/opencode", arguments: [], hook: nil)
    let choices = [shell, opencode]

    #expect(CommandPrefix.route(.character("n"), mode: .terminal, launcher: choices, directLauncherSelection: true)
        == (.terminal, .sendKey(.character("n"))))
    #expect(CommandPrefix.route(.character("1"), mode: .terminal, launcher: choices, directLauncherSelection: true)
        == (.terminal, .launch(shell)))
    #expect(CommandPrefix.route(.character("2"), mode: .terminal, launcher: choices, directLauncherSelection: true)
        == (.terminal, .launch(opencode)))
    #expect(CommandPrefix.route(.character("1"), mode: .terminal, launcher: choices)
        == (.terminal, .sendKey(.character("1"))))
}

@Test func runOverlayEditsInputAndAcceptsExplicitResourceProfile() {
    let run = RuntimeLaunchChoice(id: "run", title: "Run command", executable: "", arguments: [], hook: nil)
    let opened = CommandPrefix.route(.character("1"), mode: .launcher, launcher: [run])
    #expect(opened.0 == .runCommand(input: "", error: nil))
    let typed = CommandPrefix.route(.character("a"), mode: opened.0, launcher: [run])
    #expect(typed.0 == .runCommand(input: "a", error: nil))
    #expect(CommandPrefix.route(.enter, mode: typed.0, launcher: [run]).1 == .submitRunCommand("a"))
    let selected = RunCommandSelection.splitProfile("profile:docs /usr/bin/python3 script.py")
    #expect(selected?.profileID == "docs")
    #expect(selected?.command == "/usr/bin/python3 script.py")
    #expect(RunCommandSelection.splitProfile("profile:bad/id /bin/sh") == nil)
}

@Test func launcherSelectionOnlyAcceptsChoicesOrEscape() {
    let shell = RuntimeLaunchChoice(id: "shell", title: "shell", executable: "/bin/sh", arguments: [], hook: nil)
    let choices = [shell]

    #expect(CommandPrefix.route(.character("1"), mode: .launcher, launcher: choices)
        == (.terminal, .launch(shell)))
    #expect(CommandPrefix.route(.escape, mode: .launcher, launcher: choices)
        == (.terminal, .dismissOverlay))
    #expect(CommandPrefix.route(.character("a"), mode: .launcher, launcher: choices)
        == (.terminal, nil))
}

@Test func paneAndTabPrefixCommandsAreSemanticActions() {
    let commands: [(Character, TUICommand)] = [
        ("v", .split(.vertical)), ("-", .split(.horizontal)),
        ("h", .focus(.left)), ("j", .focus(.down)),
        ("k", .focus(.up)), ("l", .focus(.right)),
        ("c", .newTab), ("n", .switchTab(1)), ("p", .switchTab(-1)),
        ("x", .closePane), ("z", .toggleZoom), ("a", .openLauncher),
    ]
    for (key, action) in commands {
        #expect(CommandPrefix.route(.character(key), mode: .prefix(target), launcher: []).1 == action)
    }
    #expect(CommandPrefix.route(.arrow(.up), mode: .terminal, launcher: []).1 == .sendKey(.arrow(.up)))
    #expect(CommandPrefix.route(.control("b"), mode: .prefix(target), launcher: []).1 == .send(Data([0x02])))
}

@Test func profilePrefixSetsOnlyProfileIDForAgentBasenames() {
    // The prefix is explicit UI metadata. An agent basename in the command
    // must not become hook identity downstream: only the profile travels.
    let selected = RunCommandSelection.splitProfile("profile:docs /test/bin/claude --print hi")
    #expect(selected?.profileID == "docs")
    #expect(selected?.command == "/test/bin/claude --print hi")
    #expect(RunCommandSelection.splitProfile("/test/bin/claude")?.profileID == nil)
}
