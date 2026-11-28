import Testing
import RVDomain
@testable import RVEngine

/// F2: `--propose` turns a loosen into a proposal the CLI sends to rvd and
/// never applies, so an agent may run that form. Every other form stays
/// floored, and approving stays the owner's.
@Suite("rv self-protection: proposals")
struct SelfProtectionProposeTests {
    @Test(arguments: [
        "rv allowlist add core.git:reset-hard --reason 'rebasing' --propose",
        "rv allowlist add --propose core.git:reset-hard -r rebasing",
        "rv allowlist add-command 'git reset --hard' --reason why --propose",
        "rv safety normal --propose",
        "rv proposals",
        "rv proposals p-21",
        "rv proposals list --all",
        "rv proposals reject p-21 --reason no",
        "rv packs disable core.git --propose",
        "rv packs off core.git database --propose",
        "rv protect redis off --propose",
        "rv protect off redis --propose",
    ])
    func agentsMayPropose(_ command: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)) == false)
    }

    @Test(arguments: [
        "rv allowlist add core.git:reset-hard --reason rebasing",
        "rv allowlist add core.git:reset-hard --reason x -- --propose",
        "rv allowlist add-command --reason x -- --propose",
        "rv allowlist add core.git:reset-hard --reason x $FLAG --propose",
        "rv allowlist add core.git:reset-hard --reason x --propose*",
        "rv allowlist --propose add core.git:reset-hard --reason x",
        "rv safety normal",
        "rv safety --propose normal",
        "rv safety normal -- --propose",
        "rv proposals approve p-21",
        "rv proposals approve --json p-21",
        "rv packs disable core.git",
        "rv packs --propose disable core.git",
        "rv packs disable core.git -- --propose",
        "rv packs disable $PACK --propose",
        "rv protect redis off",
        "rv protect redis off -- --propose",
        "rv protect redis $OFF --propose",
        "rv protect --propose redis off",
    ])
    func everyOtherLoosenStaysTheOwners(_ command: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)))
    }
}
