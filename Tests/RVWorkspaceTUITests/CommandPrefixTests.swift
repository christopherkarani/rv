import Foundation
import Testing
@testable import RVWorkspaceTUI

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
    #expect(CommandPrefix.route(.character("v"), mode: .prefix, launcher: []).1 == nil)
    #expect(CommandPrefix.route(.character("s"), mode: .prefix, launcher: []).1 == nil)
    #expect(CommandPrefix.route(.character("x"), mode: .prefix, launcher: []).1 == nil)
    #expect(CommandPrefix.route(.character("n"), mode: .prefix, launcher: []).1 == nil)
    #expect(CommandPrefix.route(.character("d"), mode: .prefix, launcher: []).1 == .detach)
    #expect(CommandPrefix.route(.character("?"), mode: .prefix, launcher: []).1 == .help)
    #expect(CommandPrefix.route(.escape, mode: .help, launcher: []).0 == .terminal)
    #expect(TerminalInputEncoder.bytes(for: .enter) == Data([0x0d]))
    #expect(TerminalInputEncoder.bytes(for: .control("c")) == Data([0x03]))
}

@Test func emptyWorkspaceLaunchNumbersWorkWithoutThePrefix() {
    let shell = RuntimeLaunchChoice(id: "shell", title: "shell", executable: "/bin/sh", arguments: [], hook: nil)
    let opencode = RuntimeLaunchChoice(id: "opencode", title: "opencode", executable: "/bin/opencode", arguments: [], hook: nil)
    let choices = [shell, opencode]

    #expect(CommandPrefix.route(.character("n"), mode: .terminal, launcher: choices, directLauncherSelection: true)
        == (.terminal, .send(Data("n".utf8))))
    #expect(CommandPrefix.route(.character("1"), mode: .terminal, launcher: choices, directLauncherSelection: true)
        == (.terminal, .launch(shell)))
    #expect(CommandPrefix.route(.character("2"), mode: .terminal, launcher: choices, directLauncherSelection: true)
        == (.terminal, .launch(opencode)))
    #expect(CommandPrefix.route(.character("1"), mode: .terminal, launcher: choices)
        == (.terminal, .send(Data("1".utf8))))
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
