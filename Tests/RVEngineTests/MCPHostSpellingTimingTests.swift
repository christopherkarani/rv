import Foundation
import RVDomain
import Testing
@testable import RVEngine

/// Temporary measurement for review 13 L5: where the guard's time goes on a
/// line of 16 000 dynamic words. Prints `L5TIMING` lines; asserts nothing
/// about time.
struct MCPHostSpellingTimingTests {
    @Test("L5 timing of the guard's passes on 16 000 dynamic words")
    func l5Timings() {
        let clock = ContinuousClock()
        func ms(_ duration: Duration) -> Int {
            Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
        }
        for dynamic in ["$a", "${a}", "$(a)"] {
            let line = "stdbuf -o0 " + Array(repeating: dynamic, count: 16_000).joined(separator: " ") + " x"
            var tokens = 0
            let tokenize = clock.measure { tokens = ShellPipeline.tokenize(line).count }
            var segments = 0
            let split = clock.measure { segments = splitSegments(line).count }
            var launched: [LaunchedCommand] = []
            let heads = clock.measure { launched = launchedCommandHeads(line) }
            var reads = HostTextReads()
            reads.commandsArePlain = true
            var mutation = false
            let mutations = clock.measure {
                for command in launched {
                    if isHostMCPMutation(command, reads: &reads) {
                        mutation = true
                        break
                    }
                }
            }
            var mayName = false
            let name = clock.measure { mayName = mayNameHostMCP(line, budget: &reads.spelling) }
            var unfollowable = false
            let unfollow = clock.measure { unfollowable = hostMCPTextIsUnfollowable(line, launched, reads: &reads) }
            var carried = false
            let carries = clock.measure { carried = carriesHostMCPText(launched, reads: &reads, line: line) }
            var named = false
            let names = clock.measure { named = hostMCPTextNamesMutation(line, reads: &reads) }
            var whole = HostTextReads()
            var verdict = false
            let total = clock.measure {
                let context = FilesystemAnalysisContext(homeDirectory: nil, mcpHostConfigGuard: MCPHostConfigGuard())
                verdict = mcpHostConfigUnmodeledWrite(line, guard: MCPHostConfigGuard(), context: context, reads: &whole)
            }
            print(
                "L5TIMING word=\(dynamic) bytes=\(line.utf8.count) tokens=\(tokens) segments=\(segments)"
                    + " launched=\(launched.count) tokenize=\(ms(tokenize)) split=\(ms(split))"
                    + " heads=\(ms(heads)) mutation=\(ms(mutations))/\(mutation) mayName=\(ms(name))/\(mayName)"
                    + " unfollowable=\(ms(unfollow))/\(unfollowable) carries=\(ms(carries))/\(carried)"
                    + " names=\(ms(names))/\(named) total=\(ms(total))/\(verdict)"
                    + " readsDone=\(whole.readsDone) pieces=\(whole.piecesExamined) visits=\(whole.wordVisits)"
            )
        }
    }
}
