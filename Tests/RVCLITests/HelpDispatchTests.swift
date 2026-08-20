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

@Test func helpTopic_subcommands() {
    #expect(HelpDispatch.topic(arguments: ["help", "test"]) == .test)
    #expect(HelpDispatch.topic(arguments: ["test", "--help"]) == .test)
    #expect(HelpDispatch.topic(arguments: ["test", "-h"]) == .test)
    #expect(HelpDispatch.topic(arguments: ["test", "--explain", "--help"]) == .test)
    #expect(HelpDispatch.topic(arguments: ["explain", "--help"]) == .explain)
    #expect(HelpDispatch.topic(arguments: ["service", "--help"]) == .service)
    #expect(HelpDispatch.topic(arguments: ["help", "service", "status"]) == .serviceStatus)
    #expect(HelpDispatch.topic(arguments: ["service", "status", "--help"]) == .serviceStatus)
    #expect(HelpDispatch.topic(arguments: ["hook", "--help"]) == .hook)
    #expect(HelpDispatch.topic(arguments: ["hook", "--host", "pi", "--help"]) == .hook)
    #expect(HelpDispatch.topic(arguments: ["setup", "--help"]) == .setup)
    #expect(HelpDispatch.topic(arguments: ["setup", "--force", "--help"]) == .setup)
    #expect(HelpDispatch.topic(arguments: ["uninstall", "-h"]) == .uninstall)
    #expect(HelpDispatch.topic(arguments: ["uninstall", "--robot", "--help"]) == .uninstall)
    #expect(HelpDispatch.topic(arguments: ["doctor", "--help"]) == .doctor)
}

@Test func helpTopic_doesNotStealCommandArgs() {
    #expect(HelpDispatch.topic(arguments: ["test", "git", "status"]) == nil)
    #expect(HelpDispatch.topic(arguments: ["test", "echo", "--help"]) == nil)
    #expect(HelpDispatch.topic(arguments: ["explain", "rm", "-rf", "/"]) == nil)
    #expect(HelpDispatch.topic(arguments: ["service", "status"]) == nil)
    #expect(HelpDispatch.topic(arguments: ["setup"]) == nil)
}

@Test func helpTopic_unknownHelpPathFallsBackToRoot() {
    #expect(HelpDispatch.topic(arguments: ["help", "nope"]) == .root)
}

@Test func helpText_root_includesGroupsAndNext() {
    let text = HelpDispatch.text(.root, palette: colorOffPalette)
    #expect(text.contains("Get started"))
    #expect(text.contains("Everyday"))
    #expect(text.contains("Advanced"))
    #expect(text.contains("Examples"))
    #expect(text.contains("Next"))
    #expect(text.contains("rv setup"))
    #expect(text.contains("rv help setup"))
    #expect(text.contains("rv help test") == false)
    #expect(text.contains("OVERVIEW:") == false)
    #expect(text.contains("SUBCOMMANDS:") == false)
}

@Test func helpText_setup_keepsOneLineCopy() {
    let text = HelpDispatch.text(.setup, palette: colorOffPalette)
    #expect(text.contains("One line, no circles"))
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

@Test func helpText_hook_hasNoFakeFileExamples() {
    let text = HelpDispatch.text(.hook, palette: colorOffPalette)
    #expect(text.contains("Examples") == false)
    #expect(text.contains("event.json") == false)
    #expect(text.contains("Next") == false)
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
    #expect(status.contains("Next") == false)
}

@Test func helpText_leafPagesOmitTitleAndNext() {
    for topic: HelpTopic in [.test, .explain, .doctor, .service, .serviceStatus, .hook, .help] {
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
