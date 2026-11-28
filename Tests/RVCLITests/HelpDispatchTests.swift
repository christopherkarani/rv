import RVDomain
import Testing
import RVTheme
@testable import RVCLI

@Test func helpTopic_rootInvocations() {
    #expect(HelpDispatch.topic(arguments: []) == .root)
    #expect(HelpDispatch.topic(arguments: ["--help"]) == .root)
    #expect(HelpDispatch.topic(arguments: ["-h"]) == .root)
    #expect(HelpDispatch.topic(arguments: ["help"]) == .root)
    #expect(HelpDispatch.topic(arguments: ["help", "--help"]) == .root)
    #expect(HelpDispatch.topic(arguments: ["help", "help"]) == .help)
}

// Which flags and positionals each command takes is not listed here:
// HelpGrammarTests derives `--help` after every one of them from the parser.

@Test func helpTopic_nestedCommandsShowTheirOwnPage() {
    #expect(HelpDispatch.topic(arguments: ["help", "service", "status"]) == .serviceStatus)
    #expect(HelpDispatch.topic(arguments: ["service", "status", "--help"]) == .serviceStatus)
    #expect(HelpDispatch.topic(arguments: ["service", "start", "--help"]) == .serviceRestart)
    #expect(HelpDispatch.topic(arguments: ["help", "packs", "enable"]) == .packs)
    #expect(HelpDispatch.topic(arguments: ["help", "workspace", "abandon"]) == .workspace)
    #expect(HelpDispatch.topic(arguments: ["workspace", "run", "--microvm", "alpine:3.20", "--help"]) == .workspace)
    #expect(HelpDispatch.topic(arguments: ["workspace", "upload", "src", "--help"]) == .workspace)
}

@Test func helpTopic_passthroughBoundaryKeepsTheCommandsHelp() {
    // A bare `--` is a passthrough boundary: `--help` past it belongs to
    // the executable, never to help dispatch.
    #expect(HelpDispatch.topic(arguments: ["workspace", "run", "--", "--help"]) == nil)
    #expect(HelpDispatch.topic(arguments: ["opencode", "--", "--help"]) == nil)
    #expect(HelpDispatch.topic(arguments: ["workspace", "run", "--rows", "5", "--", "x", "--help"]) == nil)
}

@Test func helpTopic_doesNotStealCommandArgs() {
    #expect(HelpDispatch.topic(arguments: ["test", "git", "status"]) == nil)
    #expect(HelpDispatch.topic(arguments: ["test", "echo", "--help"]) == nil)
    #expect(HelpDispatch.topic(arguments: ["explain", "rm", "-rf", "/"]) == nil)
    #expect(HelpDispatch.topic(arguments: ["service", "status"]) == nil)
    #expect(HelpDispatch.topic(arguments: ["setup"]) == nil)
}

@Test func helpTopic_unknownOptionFollowsTheParser() {
    // ArgumentParser answers an unknown option before --help with its own
    // help, so rv answers with its page; on a passthrough command the
    // unknown option starts the captured command, --help included.
    #expect(HelpDispatch.topic(arguments: ["doctor", "--force", "--help"]) == .doctor)
    #expect(HelpDispatch.topic(arguments: ["explain", "--force", "--help"]) == nil)
    // An option still waiting for its value: the parser reports the
    // missing value, so the help flag is not rv's.
    #expect(HelpDispatch.topic(arguments: ["hook", "--host", "--help"]) == nil)
}

@Test func helpTopic_unknownHelpPathFallsBackToRoot() {
    #expect(HelpDispatch.topic(arguments: ["help", "nope"]) == .root)
}

@Test func helpText_root_includesGroupsAndNext() {
    let text = HelpDispatch.text(.root, palette: colorOffPalette)
    #expect(text.hasPrefix("◆ rv  "))
    for group in ["Get started", "Everyday", "Rules", "Team", "Advanced"] {
        #expect(text.contains("\n\(group)\n"), "root help missing group \(group)")
    }
    #expect(text.hasSuffix("  → rv setup    wire your agents and start rvd\n"))
    for name in ["why", "unlock", "guard", "watch", "packs", "scan", "policy", "allowlist", "safety", "blocks"] {
        #expect(text.contains(name), "root help missing \(name)")
    }
    #expect(text.contains("Examples") == false)
    #expect(text.contains("OVERVIEW:") == false)
    #expect(text.contains("SUBCOMMANDS:") == false)
}

/// North Star A2: five groups in this order, under 30 lines, inside an
/// 80-column terminal.
@Test func helpText_root_fitsOneScreen() {
    let page = HelpCatalog.page(.root)
    #expect(page.sections.map(\.heading) == ["Get started", "Everyday", "Rules", "Team", "Advanced"])
    let lines = HelpDispatch.text(.root, palette: colorOffPalette).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
    #expect(lines.count < 30, "rv --help is \(lines.count) lines")
    let wide = lines.filter { $0.count > 80 }
    #expect(wide.isEmpty, "rv --help lines over 80 columns: \(wide)")
}

@Test func helpText_allowOnce_namesRedeemNotCommandMint() {
    let text = HelpDispatch.text(.allowOnce, palette: colorOffPalette)
    #expect(text.contains("rv allow-once a1b2c3"))
    #expect(text.contains("six-character"))
    #expect(text.contains("rv allow-once 'git reset --hard'") == false)
}

@Test func helpText_setup_namesTheJSONDocument() {
    let text = HelpDispatch.text(.setup, palette: colorOffPalette)
    #expect(text.contains("One rv.setup.v1 JSON document"))
    #expect(text.contains("Robot JSON") == false)
}

@Test func helpText_setup_examplesAreSetupOnly() {
    let text = HelpDispatch.text(.setup, palette: colorOffPalette)
    #expect(text.contains("Examples"))
    #expect(text.contains("→ rv setup"))
    #expect(text.contains("→ rv setup --force"))
    #expect(text.contains("→ rv setup --robot"))
    #expect(text.contains("After setup"))
    #expect(text.contains("rv test 'git reset --hard'"))
    let examplesBlock = text.split(separator: "After setup")[0]
    #expect(examplesBlock.contains("rv test") == false)
}

@Test func helpText_helpMeta_hasNoExamples() {
    let text = HelpDispatch.text(.help, palette: colorOffPalette)
    #expect(text.contains("Examples") == false)
}

@Test func helpText_workspaceListsTheTUICommand() {
    let text = HelpDispatch.text(.workspace, palette: colorOffPalette)
    #expect(text.contains("rv workspace tui [--workspace <project-path>]"))
    #expect(text.contains("Interactive terminal workspace for contained runtimes"))
}

@Test func helpText_workspaceListsTheAbandonCommand() {
    let text = HelpDispatch.text(.workspace, palette: colorOffPalette)
    #expect(text.contains("rv workspace abandon [--workspace <absolute-path>]"))
    #expect(text.contains("Discard a blocked workspace's unpublished volume and restore the saved tree"))
}

@Test func helpText_hook_hasNoFakeFileExamples() {
    let text = HelpDispatch.text(.hook, palette: colorOffPalette)
    #expect(text.contains("Examples") == false)
    #expect(text.contains("event.json") == false)
    #expect(text.contains("Next") == false)
    #expect(text.contains("openclaw, hermes, codex, cursor"))
}

@Test func helpText_uninstall_hasNoPasteableTeardown() {
    let text = HelpDispatch.text(.uninstall, palette: colorOffPalette)
    #expect(text.contains("Examples") == false)
    #expect(text.contains("After uninstall"))
}

@Test func helpText_service_defersFlagsToStatus() {
    let service = HelpDispatch.text(.service, palette: colorOffPalette)
    #expect(service.contains("→ rv service"))
    #expect(service.contains("--json") == false)
    #expect(service.contains("Next") == false)

    let status = HelpDispatch.text(.serviceStatus, palette: colorOffPalette)
    #expect(status.contains("→ rv service status"))
    #expect(status.contains("→ rv service status --robot"))
    #expect(status.contains("JSON document (same as --robot)"))
    #expect(status.contains("key=value lines"))
    #expect(status.contains("Robot JSON") == false)
    #expect(status.contains("Next") == false)
}

@Test func helpText_leafPagesOmitTitleAndNext() {
    for topic: HelpTopic in [
        .test, .explain, .doctor, .service, .serviceStatus, .hook, .help,
        .packs, .scan, .policy, .allowlist, .safety, .blocks, .workspace,
    ] {
        let text = HelpDispatch.text(topic, palette: colorOffPalette)
        #expect(text.hasPrefix("Usage") || text.hasPrefix("\n") == false)
        #expect(text.contains("Next") == false)
        #expect(text.split(separator: "\n").first.map(String.init) == "Usage")
    }
}

@Test func helpText_setupAndUninstallKeepWorkflowNext() {
    let setup = HelpDispatch.text(.setup, palette: colorOffPalette)
    #expect(setup.contains("After setup"))
    #expect(setup.contains("rv test 'git reset --hard'"))

    let uninstall = HelpDispatch.text(.uninstall, palette: colorOffPalette)
    #expect(uninstall.contains("After uninstall"))
    #expect(uninstall.contains("rv setup"))
}

@Test func helpText_serviceRestart_isDispatchedAndListed() {
    #expect(HelpDispatch.topic(arguments: ["service", "restart", "--help"]) == .serviceRestart)
    #expect(HelpDispatch.topic(arguments: ["help", "service", "restart"]) == .serviceRestart)
    #expect(HelpDispatch.topic(arguments: ["service", "restart"]) == nil)

    let service = HelpDispatch.text(.service, palette: colorOffPalette)
    #expect(service.contains("restart"))

    let restart = HelpDispatch.text(.serviceRestart, palette: colorOffPalette)
    #expect(restart.split(separator: "\n").first.map(String.init) == "Usage")
    #expect(restart.contains("rv service restart"))
    #expect(restart.contains("rv service start"))
    #if os(Linux)
    #expect(restart.contains("systemctl --user restart"))
    #expect(restart.contains("No systemd user manager"))
    #expect(restart.contains("kickstart") == false)
    #else
    #expect(restart.contains("kickstart"))
    #endif
    #expect(HelpDispatch.topic(arguments: ["service", "start", "--help"]) == .serviceRestart)
    #expect(service.contains("start"))
}

/// Every command a person types is on the root page; the commands rv
/// runs for programs (`rv hook`, `rv operator`) keep their own pages.
@Test func helpText_root_listsEveryParserCommand() {
    let listed = Set(HelpCatalog.page(.root).sections.flatMap(\.rows).flatMap(HelpCatalog.commands(in:)))
    let hidden = Set(UnknownCommand.internalCommands.map(\.rawValue))
    let names = RV.configuration.subcommands.compactMap { $0.configuration.commandName }
    // A command shown by its new name (`why` for `explain`) counts.
    let shownAs = Dictionary(grouping: CommandVocabulary.Alias.allCases.filter { $0.words.count == 1 }, by: { $0.runs[0] })
    for name in names where hidden.contains(name) == false {
        let spellings = [name] + (shownAs[name] ?? []).map(\.rawValue)
        #expect(spellings.contains(where: listed.contains), "root help missing \(name)")
    }
    #expect(listed.isDisjoint(with: hidden))
}

@Test func helpTopic_everyParserCommand_resolvesToOwnTopic() {
    let names = RV.configuration.subcommands.compactMap { $0.configuration.commandName }
    #expect(names.isEmpty == false)
    for name in names {
        let viaHelp = HelpDispatch.topic(arguments: ["help", name])
        #expect(viaHelp != nil && viaHelp != .root, "`rv help \(name)` falls back to root")
        let viaFlag = HelpDispatch.topic(arguments: [name, "--help"])
        #expect(viaFlag != nil && viaFlag != .root, "`rv \(name) --help` has no styled topic")
    }
}

@Test func helpText_login_documentsSubcommandsAndFlags() {
    #expect(HelpDispatch.topic(arguments: ["help", "login"]) == .login)
    #expect(HelpDispatch.topic(arguments: ["login", "--help"]) == .login)
    let text = HelpDispatch.text(.login, palette: colorOffPalette)
    #expect(text.split(separator: "\n").first.map(String.init) == "Usage")
    let subcommands = Login.configuration.subcommands.compactMap { $0.configuration.commandName }
    #expect(subcommands.isEmpty == false)
    for name in subcommands {
        #expect(HelpDispatch.topic(arguments: ["login", name, "--help"]) == .login, "`rv login \(name) --help` is not the login page")
        #expect(HelpDispatch.topic(arguments: ["help", "login", name]) == .login, "`rv help login \(name)` is not the login page")
        #expect(text.contains("rv login \(name)") || text.contains("rv login [\(name)]"), "login help missing `rv login \(name)`")
    }
    for provider in LoginProvider.all {
        #expect(text.contains(provider.id), "login help missing provider \(provider.id)")
    }
    for needle in ["--stdin", "--resource-profile"] {
        #expect(text.contains(needle), "login help missing \(needle)")
    }
}

@Test func helpText_test_documentsDenyExitCode() {
    let text = HelpDispatch.text(.test, palette: colorOffPalette)
    #expect(text.contains("Exit codes"))
    #expect(text.contains("Deny"))
    #expect(text.contains("1"))
}

@Test func helpText_testAndExplain_documentObserveMode() {
    for topic in [HelpTopic.test, .explain] {
        let text = HelpDispatch.text(topic, palette: colorOffPalette)
        #expect(text.contains("Observe mode"), "\(topic) help missing observe mode")
        #expect(text.contains("would ask"), "\(topic) help missing the would-be ask")
        let flowed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(
            flowed.contains("or block (a pinned deny, or an evaluation it could not finish)"),
            "\(topic) help missing the would-be block"
        )
    }
}

@Test func helpTopic_operator() {
    #expect(HelpDispatch.topic(arguments: ["operator", "--help"]) == .`operator`)
    #expect(HelpDispatch.topic(arguments: ["help", "operator"]) == .`operator`)
    #expect(HelpDispatch.topic(arguments: ["operator", "propose", "--help"]) == .`operator`)
}

@Test func helpText_scopesPlatformByFeature() {
    let root = HelpDispatch.text(.root, palette: colorOffPalette)
    #expect(root.contains("macOS only"), "root must scope contained runtime to macOS")
    let opencode = HelpDispatch.text(.opencode, palette: colorOffPalette)
    #expect(opencode.contains("macOS-only") || opencode.contains("macOS only"))
    #expect(opencode.contains("Hook guard"))
    #expect(opencode.contains("Linux"))
    let workspace = HelpDispatch.text(.workspace, palette: colorOffPalette)
    #expect(workspace.contains("macOS-only") || workspace.contains("macOS only"))
    #expect(workspace.contains("Hook guard"))
    #expect(workspace.contains("docs/security/runtime-boundary.md"))
    let hook = HelpDispatch.text(.hook, palette: colorOffPalette)
    #expect(hook.contains("works on Linux"))
    #expect(hook.contains("macOS-only") || hook.contains("macOS only"))
}
