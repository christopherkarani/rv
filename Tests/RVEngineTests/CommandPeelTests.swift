import Testing
import RVDomain
@testable import RVEngine

@Suite("CommandPeel")
struct CommandPeelTests {
    @Test func peel_sudo_sharesMatchingAndExecuting() {
        let command = ShellCommand(rawValue: "sudo git reset --hard")
        guard case .complete(let matching, let executing, let layers) = CommandPeelCore.peel(command)
        else {
            Issue.record("sudo git reset must peel completely")
            return
        }
        #expect(matching == Normalize.matchingView(of: command))
        #expect(matching.rawValue == "git reset --hard")
        #expect(executing.rawValue == "git reset --hard")
        #expect(layers == [.sudo])
        #expect(
            analyzeGit(executing) == analyzeGit(ExecutingCommand(rawValue: "git reset --hard"))
        )
    }

    @Test func peel_bashDashC_keepsGrantKeyAndExposesExecuting() {
        let command = ShellCommand(rawValue: "bash -c 'git reset --hard'")
        guard case .complete(let matching, let executing, let layers) = CommandPeelCore.peel(command)
        else {
            Issue.record("bash -c git reset must peel completely")
            return
        }
        #expect(matching == Normalize.matchingView(of: command))
        #expect(matching.rawValue.contains("bash"))
        #expect(executing.rawValue == "git reset --hard")
        #expect(layers == [.bash])
        #expect(analyzeGit(ExecutingCommand(rawValue: command.rawValue)) == .unknown)
        #expect(analyzeGit(executing) == .git(.reset(mode: .hard, target: nil)))
    }

    @Test func peel_unknownSudoFlag_isLimitedAndKeepsGrantKey() {
        let command = ShellCommand(rawValue: "sudo --not-a-flag git status")
        guard case .limited(let matching, let layers) = CommandPeelCore.peel(command) else {
            Issue.record("unknown sudo flag must be limited")
            return
        }
        #expect(matching == Normalize.matchingView(of: command))
        #expect(matching.rawValue.contains("sudo"))
        #expect(layers == [.sudo])
    }

    @Test func matchingView_forwardsNormalize() {
        #expect(
            CommandPeelCore.matchingView(of: "  sudo git status  ")
                == Normalize.matchingView(of: "  sudo git status  ")
        )
    }
}
