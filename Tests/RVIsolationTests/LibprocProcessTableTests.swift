#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RVIsolation

/// libproc's reads against real processes.
@Suite("libproc process table")
struct LibprocProcessTableTests {
    /// A child spawned with `POSIX_SPAWN_CLOEXEC_DEFAULT` and no file actions
    /// (a placeholder launch with no descriptors) has an empty descriptor
    /// table. That is an answer, not a failed read: it holds no socket, so a
    /// connection from outside its group is an outsider (`runtimeMismatch`,
    /// a misuse finding), not `unverifiable`.
    @Test(.timeLimit(.minutes(1)))
    func aProcessWithNoDescriptorsHoldsNoSocket() throws {
        let leader = try spawnWithoutDescriptors()
        // SIGKILL before the wait, so the reap cannot block.
        defer {
            kill(-leader, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(leader, &status, 0)
        }
        let table = LibprocProcessTable()
        let peer = GatewayPeer(port: 1, gatewayPort: 2)
        #expect(table.holdsSocket(leader, peer) == false)
        let group = try #require(ProcessGroupRecovery.capture(pid: leader))
        #expect(GatewayPeerScan.verdict(peer, group: group, in: table) == .outsider)
    }

    private struct SpawnFailed: Error { let code: Int32 }

    /// `/bin/sleep 30` leading its own group, with every descriptor closed at exec.
    private func spawnWithoutDescriptors() throws -> pid_t {
        var attributes: posix_spawnattr_t?
        try #require(posix_spawnattr_init(&attributes) == 0)
        defer { posix_spawnattr_destroy(&attributes) }
        try #require(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0)
        try #require(posix_spawnattr_setpgroup(&attributes, 0) == 0)
        let arguments = ["/bin/sleep", "30"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let code = posix_spawn(&pid, "/bin/sleep", nil, &attributes, &argv, &envp)
        guard code == 0 else { throw SpawnFailed(code: code) }
        return pid
    }
}
#endif
