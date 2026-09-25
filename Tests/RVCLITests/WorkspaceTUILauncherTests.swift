import Foundation
import Testing
@testable import RVCLI

#if os(macOS)
@Test func workspaceShellLauncherDisablesZshPromptSp() {
    let choices = WorkspaceTUICommand.launcherChoices()
    let shell = choices.first { $0.id == "shell" }
    let entry = try? #require(shell)
    #expect(entry?.hook == nil)
    if entry?.executable == "/bin/zsh" {
        #expect(entry?.arguments == ["-o", "NO_PROMPT_SP"])
    } else {
        #expect(entry?.executable == "/bin/sh")
        #expect(entry?.arguments == [])
    }
}
#endif
