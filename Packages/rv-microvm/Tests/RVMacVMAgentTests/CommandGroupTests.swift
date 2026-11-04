import Darwin
import Foundation
@testable import RVMacVMAgent
import Testing

@Suite("command process group")
struct CommandGroupTests {
    @Test("a leader that is not our child (ECHILD) is never signalled and never reports success")
    func lostLeader() {
        // pid 1 is never this process's child: waitid and waitpid fail with ECHILD.
        let group = CommandGroup(leader: 1)
        group.waitForExit()
        #expect(group.hasExited)
        #expect(group.reap() == CommandGroup.unknownStatus)
    }

    @Test("a reaped leader reports its real wait status")
    func reapedLeader() throws {
        var pid: pid_t = 0
        let arguments = ["/bin/sh", "-c", "exit 3"]
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/bin/sh", nil, nil, &argv, environ) == 0)
        let group = CommandGroup(leader: pid)
        group.waitForExit()
        let status = group.reap()
        #expect((status >> 8) & 0xff == 3)
    }
}
