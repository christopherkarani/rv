#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVIsolation

/// The capability `rv run` asks before it launches a runtime with brokered
/// secrets: the probe must be true on both hosts' real kernels, and false
/// whenever one of the reads it makes cannot tell.
@Suite("Gateway peer binding capability")
struct GatewayPeerBindingTests {
    /// Answers one probe from fixed values, standing in for a kernel that
    /// refuses one read. `lookup` answers in order, then repeats the last.
    final class ScriptedTable: ProcessTable {
        var lookups: [ProcessLookup]
        var listed: [pid_t]? = []
        var users: [pid_t]? = []
        var holds: Bool? = true
        var failedListingIsEmptySession = false
        private(set) var askedPeer: GatewayPeer?

        init(_ lookups: ProcessLookup...) { self.lookups = lookups }

        static let me = ProcessIdentity(pid: UInt32(getpid()), parent: 1, group: 7, startSeconds: 40, startMicroseconds: 5)

        func lookup(_ pid: pid_t) -> ProcessLookup {
            lookups.count > 1 ? lookups.removeFirst() : lookups[0]
        }
        func session(of pid: pid_t) -> pid_t? { nil }
        func children(of pid: pid_t) -> [pid_t]? { listed }
        func userProcesses() -> [pid_t]? { users }
        func holdsSocket(_ pid: pid_t, _ peer: GatewayPeer) -> Bool? {
            askedPeer = peer
            return holds
        }
        func executable(_ pid: pid_t) -> ProcessExecutable? { nil }
    }

    @Test func thisHostCanVerifyGatewayPeers() {
        #expect(GatewayPeerBinding.isVerifiable)
        #expect(GatewayPeerBinding.probe(in: HostProcessTable.make()))
    }

    /// The probe asks about a real loopback connection, named as the gateway
    /// names it: both ends on 127.0.0.1, distinct ports.
    @Test func everyReadAnsweringIsVerifiable() throws {
        let table = ScriptedTable(.found(ScriptedTable.me))
        #expect(GatewayPeerBinding.probe(in: table))
        let peer = try #require(table.askedPeer)
        #expect(peer.port != 0 && peer.gatewayPort != 0 && peer.port != peer.gatewayPort)
    }

    @Test(arguments: [ProcessLookup.absent, .unavailable])
    func thisProcessUnreadableIsNotVerifiable(_ lookup: ProcessLookup) {
        #expect(GatewayPeerBinding.probe(in: ScriptedTable(lookup)) == false)
    }

    @Test func aLookupOfAnotherPidIsNotVerifiable() {
        var other = ScriptedTable.me
        other.pid += 1
        #expect(GatewayPeerBinding.probe(in: ScriptedTable(.found(other))) == false)
    }

    @Test func anIncompleteProcessListingIsNotVerifiable() {
        let table = ScriptedTable(.found(ScriptedTable.me))
        table.listed = nil
        #expect(GatewayPeerBinding.probe(in: table) == false)
    }

    /// `/proc` reads a failed session listing as "cannot tell"; libproc as an
    /// empty session, so there the listing does not decide.
    @Test func aFailedUserListingCountsOnlyWhereTheScanIsStrict() {
        let strict = ScriptedTable(.found(ScriptedTable.me))
        strict.users = nil
        #expect(GatewayPeerBinding.probe(in: strict) == false)
        let lenient = ScriptedTable(.found(ScriptedTable.me))
        lenient.users = nil
        lenient.failedListingIsEmptySession = true
        #expect(GatewayPeerBinding.probe(in: lenient))
    }

    @Test(arguments: [false, nil] as [Bool?])
    func aSocketThisProcessIsNotSeenToHoldIsNotVerifiable(_ holds: Bool?) {
        let table = ScriptedTable(.found(ScriptedTable.me))
        table.holds = holds
        #expect(GatewayPeerBinding.probe(in: table) == false)
    }

    /// A different process under the pid after the descriptor read (a
    /// changed start time) is not this process.
    @Test func anIdentityThatChangesAcrossTheReadsIsNotVerifiable() {
        var later = ScriptedTable.me
        later.startMicroseconds += 1
        #expect(GatewayPeerBinding.probe(in: ScriptedTable(.found(ScriptedTable.me), .found(later))) == false)
        #expect(GatewayPeerBinding.probe(in: ScriptedTable(.found(ScriptedTable.me), .absent)) == false)
    }

    /// The host's own table, asked about a process that does not hold the
    /// probe's connection (this process's parent), does not see it held.
    @Test func anotherProcessOnTheRealKernelIsNotTakenForTheHolder() {
        #expect(GatewayPeerBinding.probe(pid: getppid(), in: HostProcessTable.make()) == false)
    }

    /// A `/proc` that is not there (every non-Linux host without libproc
    /// gets this table) is never a capability.
    @Test func aMissingProcIsNotVerifiable() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-noproc-\(UUID().uuidString)").path
        #expect(GatewayPeerBinding.probe(in: ProcFSProcessTable(root: root)) == false)
    }

    #if os(Linux)
    /// The real `/proc`, read as if this process had another pid (a `/proc`
    /// mounted for another pid namespace): `self` does not match.
    @Test func aProcOfAnotherPidNamespaceIsNotVerifiable() {
        #expect(GatewayPeerBinding.probe(in: ProcFSProcessTable()))
        #expect(GatewayPeerBinding.probe(in: ProcFSProcessTable(selfPID: getpid() + 1)) == false)
    }
    #endif
}
