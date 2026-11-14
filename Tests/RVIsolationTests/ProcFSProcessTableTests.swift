#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVIsolation

/// A `/proc` tree on disk. The Linux table reads it exactly as it reads the
/// kernel's, so the scan, the binary walk and group capture are exercised on
/// every host. pid 100 is "this process"; the connection is
/// `127.0.0.1:50000 -> 127.0.0.1:8080` with the client end at inode 2222.
final class ProcFixture {
    let root: String
    let selfPID: pid_t = 100
    let uid: uid_t = 1000
    let peer = GatewayPeer(port: 50_000, gatewayPort: 8080)
    static let clientInode = 2222
    private var locked: [String] = []

    static let tcpHeader = ProcFSParseTests.header
    static var connection: String {
        let little = ProcFSParse.hostIsLittleEndian
        let loopback = little ? "0100007F" : "7F000001"
        return tcpHeader
            + ProcFSParseTests.row(0, "\(loopback):1F90", "00000000:0000", state: "0A", inode: 900)
            + ProcFSParseTests.row(1, "\(loopback):1F90", "\(loopback):C350", inode: 1111)
            + ProcFSParseTests.row(2, "\(loopback):C350", "\(loopback):1F90", inode: clientInode)
    }

    init(selfLink: String? = nil, mountOptions: String = "rw", tcp: String? = connection) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-procfs-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/self", withDestinationPath: selfLink ?? "\(selfPID)")
        try process(selfPID, parent: 1, group: selfPID, session: selfPID)
        try write("\(selfPID)/mountinfo", "23 28 0:22 / \(root) rw,nosuid shared:13 - proc proc \(mountOptions)\n")
        if let tcp { try write("\(selfPID)/net/tcp", tcp) }
        try write("\(selfPID)/net/tcp6", Self.tcpHeader)
    }

    deinit {
        for path in locked { chmod(path, 0o755) }
        try? FileManager.default.removeItem(atPath: root)
    }

    var table: ProcFSProcessTable { ProcFSProcessTable(root: root, uid: uid, selfPID: selfPID, hz: 100) }

    func process(
        _ pid: pid_t, parent: pid_t, group: pid_t, session: pid_t = 50, start: UInt64 = 1_000, state: String = "S",
        uids: [uid_t]? = nil, sockets: [Int] = [], exe: String? = nil
    ) throws {
        let ids = uids ?? Array(repeating: uid, count: 4)
        try write("\(pid)/stat",
            "\(pid) (proc \(pid))) \(state) \(parent) \(group) \(session) 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 \(start) 0 0\n")
        try write("\(pid)/status", "Name:\tproc\nUid:\t" + ids.map(String.init).joined(separator: "\t") + "\nGid:\t0\t0\t0\t0\n")
        let fd = "\(root)/\(pid)/fd"
        try FileManager.default.createDirectory(atPath: fd, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fd + "/0", withDestinationPath: "/dev/null")
        try FileManager.default.createSymbolicLink(atPath: fd + "/1", withDestinationPath: "pipe:[77]")
        for (index, inode) in sockets.enumerated() {
            try FileManager.default.createSymbolicLink(atPath: fd + "/\(index + 3)", withDestinationPath: "socket:[\(inode)]")
        }
        if let exe {
            try FileManager.default.createSymbolicLink(atPath: "\(root)/\(pid)/exe", withDestinationPath: exe)
        }
    }

    func write(_ relative: String, _ text: String) throws {
        let url = URL(fileURLWithPath: root + "/" + relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(atPath: root + "/" + relative)
    }

    /// Unreadable, as `/proc/<pid>/fd` of a non-dumpable process is.
    func lock(_ relative: String) {
        let path = root + "/" + relative
        chmod(path, 0)
        locked.append(path)
    }

    func group(_ leader: pid_t) throws -> ProcessGroupFact {
        try #require(ProcessGroupRecovery.capture(pid: leader, in: table))
    }

    func verdict(_ group: ProcessGroupFact) -> GatewayPeerVerdict {
        GatewayPeerScan.verdict(peer, group: group, in: table)
    }
}

@Suite("ProcFS process table")
struct ProcFSProcessTableTests {
    /// Running as root reads through `chmod 0`; those cases then prove nothing.
    private var unprivileged: Bool { getuid() != 0 }

    // MARK: membership

    @Test func aDescendantHoldingTheClientSocketIsAMember() throws {
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200)
        try proc.process(201, parent: 200, group: 200)
        try proc.process(202, parent: 201, group: 202, sockets: [ProcFixture.clientInode])
        #expect(proc.verdict(try proc.group(200)) == .member)
    }

    @Test func theLeaderHoldingItIsAMember() throws {
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200, sockets: [5, ProcFixture.clientInode])
        #expect(proc.verdict(try proc.group(200)) == .member)
    }

    @Test func aProcessOutsideTheTreeHoldingItIsAnOutsider() throws {
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200)
        try proc.process(201, parent: 200, group: 200, sockets: [1111])
        try proc.process(300, parent: 1, group: 300, sockets: [ProcFixture.clientInode])
        #expect(proc.verdict(try proc.group(200)) == .outsider)
    }

    /// `POSIX_SPAWN_SETPGROUP` lets a same-session process join any group.
    @Test func joiningTheLeadersGroupIsNotMembership() throws {
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200)
        try proc.process(300, parent: 1, group: 200, sockets: [ProcFixture.clientInode])
        #expect(proc.verdict(try proc.group(200)) == .outsider)
    }

    @Test func aLeaderThatIsGoneReusedOrNoLongerLeadingIsUnverifiable() throws {
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200, sockets: [ProcFixture.clientInode])
        var stale = try proc.group(200)
        stale.startMicroseconds += 1
        #expect(proc.verdict(stale) == .unverifiable)
        let gone = ProcessGroupFact(pgid: try #require(ValidatedPGID(555)), startSeconds: 10, startMicroseconds: 0)
        #expect(proc.verdict(gone) == .unverifiable)
        try proc.process(201, parent: 1, group: 7, state: "Z")
        let zombie = ProcessGroupFact(pgid: try #require(ValidatedPGID(201)), startSeconds: 10, startMicroseconds: 0)
        #expect(proc.verdict(zombie) == .unverifiable)
    }

    /// A terminal runtime's leader leads its session; an orphan of it that
    /// left the group and the tree still belongs to it.
    @Test func anOrphanInTheSessionTheLeaderLeadsIsAMember() throws {
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200, session: 200)
        try proc.process(400, parent: 1, group: 400, session: 200, sockets: [ProcFixture.clientInode])
        #expect(proc.verdict(try proc.group(200)) == .member)
    }

    @Test func aSessionTheLeaderDoesNotLeadAdmitsNobody() throws {
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200, session: 50)
        try proc.process(400, parent: 1, group: 400, session: 50, sockets: [ProcFixture.clientInode])
        #expect(proc.verdict(try proc.group(200)) == .outsider)
    }

    /// Another user's process is not listed; a setuid one of this user's
    /// (real uid ours) is, and unreadable descriptors leave it undecided.
    @Test func aSetuidSessionMemberWithUnreadableDescriptorsIsUnverifiable() throws {
        guard unprivileged else { return }
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200, session: 200)
        try proc.process(400, parent: 1, group: 400, session: 200, uids: [0, 0, 0, 0], sockets: [ProcFixture.clientInode])
        #expect(proc.verdict(try proc.group(200)) == .outsider)
        try proc.process(401, parent: 1, group: 401, session: 200, uids: [1000, 0, 0, 0])
        proc.lock("401/fd")
        #expect(proc.verdict(try proc.group(200)) == .unverifiable)
    }

    // MARK: failing closed

    @Test func unreadableDescriptorsBelowTheLeaderAreUnverifiableUnlessAMemberIsFound() throws {
        guard unprivileged else { return }
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200)
        try proc.process(201, parent: 200, group: 200)
        proc.lock("201/fd")
        #expect(proc.verdict(try proc.group(200)) == .unverifiable)
        try proc.process(202, parent: 200, group: 200, sockets: [ProcFixture.clientInode])
        #expect(proc.verdict(try proc.group(200)) == .member)
    }

    /// Any `stat` that cannot be read could be a child of the leader.
    @Test(arguments: ["garbage", "locked"])
    func anyUnreadableStatMakesTheTreeIncomplete(kind: String) throws {
        guard unprivileged || kind == "garbage" else { return }
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200)
        try proc.process(999, parent: 1, group: 999)
        if kind == "garbage" { try proc.write("999/stat", "999 (x\n") } else { proc.lock("999/stat") }
        #expect(proc.verdict(try proc.group(200)) == .unverifiable)
    }

    @Test(arguments: ["101", "nothing"])
    func aProcThatIsNotThisProcesssCannotTell(link: String) throws {
        let proc = try ProcFixture(selfLink: link)
        try proc.process(200, parent: 1, group: 200)
        try proc.process(201, parent: 200, group: 200, sockets: [ProcFixture.clientInode])
        #expect(proc.verdict(try proc.group(200)) == .unverifiable)
    }

    @Test(arguments: ["rw,hidepid=2", "rw,hidepid=invisible", "rw,hidepid=1"])
    func aProcThatHidesProcessesCannotTell(options: String) throws {
        let proc = try ProcFixture(mountOptions: options)
        try proc.process(200, parent: 1, group: 200, sockets: [ProcFixture.clientInode])
        #expect(proc.verdict(try proc.group(200)) == .unverifiable)
    }

    @Test(arguments: [0, 1, 2, 3])
    func aSocketTableThatDoesNotNameOneHeldClientEndCannotTell(variant: Int) throws {
        let loopback = ProcFSParse.hostIsLittleEndian ? "0100007F" : "7F000001"
        let gateway = ProcFSParseTests.row(1, "\(loopback):1F90", "\(loopback):C350", inode: 1111)
        let tables: [String?] = [
            nil,  // missing
            ProcFixture.tcpHeader + gateway + ProcFSParseTests.row(2, "\(loopback):C350", "\(loopback):1F90", inode: 0),
            String(ProcFixture.connection.dropLast()),  // truncated
            ProcFixture.connection + ProcFSParseTests.row(3, "\(loopback):C350", "\(loopback):1F90", inode: 3333),
        ]
        let proc = try ProcFixture(tcp: tables[variant])
        try proc.process(200, parent: 1, group: 200, sockets: [ProcFixture.clientInode])
        #expect(proc.verdict(try proc.group(200)) == .unverifiable)
    }

    @Test func noTCP6TableIsIPv6DisabledButAnUnreadableOneCannotTell() throws {
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200, sockets: [ProcFixture.clientInode])
        try proc.remove("\(proc.selfPID)/net/tcp6")
        #expect(proc.verdict(try proc.group(200)) == .member)
        guard unprivileged else { return }
        try proc.write("\(proc.selfPID)/net/tcp6", ProcFixture.tcpHeader)
        proc.lock("\(proc.selfPID)/net/tcp6")
        #expect(proc.verdict(try proc.group(200)) == .unverifiable)
    }

    /// The client end may be a dual-stack socket, listed in `tcp6`.
    @Test func aV4MappedClientEndInTCP6IsFound() throws {
        let mapped = ProcFSParse.hostIsLittleEndian
            ? "0000000000000000FFFF00000100007F" : "00000000000000000000FFFF7F000001"
        let loopback = ProcFSParse.hostIsLittleEndian ? "0100007F" : "7F000001"
        let proc = try ProcFixture(
            tcp: ProcFixture.tcpHeader + ProcFSParseTests.row(0, "\(loopback):1F90", "\(loopback):C350", inode: 1111))
        try proc.write("\(proc.selfPID)/net/tcp6",
            ProcFixture.tcpHeader + ProcFSParseTests.row(0, "\(mapped):C350", "\(mapped):1F90", inode: ProcFixture.clientInode))
        try proc.process(200, parent: 1, group: 200, sockets: [ProcFixture.clientInode])
        #expect(proc.verdict(try proc.group(200)) == .member)
    }

    /// Listed, then gone before its descriptors were read: it may have been
    /// the holder, so the scan cannot call the peer an outsider. Gone before
    /// the listing, it is simply not part of the runtime.
    @Test func aDescendantThatExitsMidScanIsUnverifiableNotOutsider() throws {
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200)
        try proc.process(201, parent: 200, group: 200)
        let group = try proc.group(200)
        let table = proc.table
        #expect(table.children(of: 200) == [201])
        try proc.remove("201")
        #expect(GatewayPeerScan.verdict(proc.peer, group: group, in: table) == .unverifiable)
        #expect(proc.verdict(group) == .outsider)
    }

    /// The child exited and its pid went to an unrelated process: the
    /// re-check after the match sees a different parent.
    @Test func aPidReusedAfterTheListingIsNotTakenForTheChild() throws {
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200)
        try proc.process(201, parent: 200, group: 200)
        let group = try proc.group(200)
        let table = proc.table
        #expect(table.children(of: 200) == [201])
        try proc.remove("201")
        try proc.process(201, parent: 1, group: 201, start: 5_000, sockets: [ProcFixture.clientInode])
        #expect(GatewayPeerScan.verdict(proc.peer, group: group, in: table) == .outsider)
    }

    // MARK: holders and binaries

    @Test func everyRuntimeHolderOfASharedSocketIsListed() throws {
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200, start: 1_000, sockets: [ProcFixture.clientInode])
        try proc.process(201, parent: 200, group: 200, start: 1_234, sockets: [ProcFixture.clientInode])
        try proc.process(300, parent: 1, group: 300, sockets: [ProcFixture.clientInode])
        let holders = try #require(GatewayPeerScan.holders(proc.peer, group: try proc.group(200), in: proc.table))
        #expect(holders == [
            GatewayHolder(pid: 200, startSeconds: 10, startMicroseconds: 0),
            GatewayHolder(pid: 201, startSeconds: 12, startMicroseconds: 340_000),
        ])
    }

    @Test func binaryBindingWalksTheFixtureTree() throws {
        // Links name the resolved paths, as the kernel reports them.
        let sh = try GatewayBinaryPin.pin("/bin/sh").get()
        let ls = try GatewayBinaryPin.pin("/bin/ls").get()
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200, exe: ls.path)
        try proc.process(201, parent: 200, group: 200, sockets: [ProcFixture.clientInode], exe: sh.path)
        #expect(GatewayPeerScan.binaries(proc.peer, group: try proc.group(200), pins: [sh], in: proc.table) == .allowed)
    }

    @Test func everyHolderMustRunOrDescendFromAPinnedBinary() throws {
        let sh = try GatewayBinaryPin.pin("/bin/sh").get()
        let ls = try GatewayBinaryPin.pin("/bin/ls").get()
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200, sockets: [ProcFixture.clientInode], exe: ls.path)
        try proc.process(201, parent: 200, group: 200, sockets: [ProcFixture.clientInode], exe: sh.path)
        let group = try proc.group(200)
        #expect(GatewayPeerScan.binaries(proc.peer, group: group, pins: [sh], in: proc.table) == .mismatch)
        // The leader passes as ls; the child as sh or as ls's descendant.
        #expect(GatewayPeerScan.binaries(proc.peer, group: group, pins: [ls], in: proc.table) == .allowed)
    }

    /// The kernel marks a replaced or removed binary ` (deleted)`. Even a
    /// pinned file whose name really ends that way does not match it.
    @Test func aDeletedExecutableNeverMatches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-deleted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appendingPathComponent("tool (deleted)")
        try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: tool)
        let pin = try GatewayBinaryPin.pin(tool.path).get()
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200, exe: "/bin/ls")
        try proc.process(201, parent: 200, group: 200, sockets: [ProcFixture.clientInode], exe: pin.path)
        #expect(GatewayPeerScan.binaries(proc.peer, group: try proc.group(200), pins: [pin], in: proc.table) == .mismatch)
    }

    @Test func anExecutableThatCannotBeReadIsUnverifiable() throws {
        let sh = try GatewayBinaryPin.pin("/bin/sh").get()
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200, exe: sh.path)
        try proc.process(201, parent: 200, group: 200, sockets: [ProcFixture.clientInode], exe: "/nonexistent/tool")
        #expect(GatewayPeerScan.binaries(proc.peer, group: try proc.group(200), pins: [sh], in: proc.table)
            == .unverifiable)
    }

    // MARK: group capture

    @Test func captureRecordsALeadersStartAsSecondsAndMicroseconds() throws {
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200, start: 123_456)
        try proc.process(201, parent: 200, group: 200)
        try proc.process(202, parent: 1, group: 202, state: "Z")
        let table = proc.table
        #expect(ProcessGroupRecovery.capture(pid: 200, in: table)
            == ProcessGroupFact(pgid: try #require(ValidatedPGID(200)), startSeconds: 1_234, startMicroseconds: 560_000))
        #expect(ProcessGroupRecovery.capture(pid: 201, in: table) == nil)
        #expect(ProcessGroupRecovery.capture(pid: 202, in: table) == nil)
        #expect(ProcessGroupRecovery.capture(pid: 203, in: table) == nil)
        #expect(ProcessGroupRecovery.capture(pid: 1, in: table) == nil)
        let noClock = ProcFSProcessTable(root: proc.root, uid: proc.uid, selfPID: proc.selfPID, hz: nil)
        #expect(noClock.lookup(200) == .unavailable)
    }

    @Test func userProcessesAreThoseWhoseRealEffectiveOrSavedUidIsOurs() throws {
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200)
        try proc.process(201, parent: 1, group: 201, uids: [0, 1000, 0, 0])
        try proc.process(202, parent: 1, group: 202, uids: [0, 0, 1000, 0])
        try proc.process(203, parent: 1, group: 203, uids: [0, 0, 0, 1000])
        try proc.process(204, parent: 1, group: 204, uids: [0, 0, 0, 0])
        #expect(proc.table.userProcesses().map(Set.init) == [100, 200, 201, 202])
        try proc.write("204/status", "Name:\tx\n")
        #expect(proc.table.userProcesses() == nil)
    }

    // MARK: reader

    @Test func readerSeparatesGoneFromUnreadable() throws {
        let proc = try ProcFixture()
        try proc.process(200, parent: 1, group: 200, exe: "/bin/sh")
        guard case .absent = ProcFSReader.file(proc.root + "/999/stat") else { Issue.record("missing file"); return }
        guard case .absent = ProcFSReader.directory(proc.root + "/999/fd") else { Issue.record("missing dir"); return }
        guard case .absent = ProcFSReader.link(proc.root + "/999/exe") else { Issue.record("missing link"); return }
        guard case .value(let target) = ProcFSReader.link(proc.root + "/200/exe"), target == "/bin/sh" else {
            Issue.record("link")
            return
        }
        guard case .unavailable = ProcFSReader.link(proc.root + "/200/stat") else { Issue.record("not a link"); return }
        guard case .value(let names) = ProcFSReader.directory(proc.root + "/200/fd"), Set(names) == ["0", "1"] else {
            Issue.record("listing")
            return
        }
        guard unprivileged else { return }
        proc.lock("200/stat")
        guard case .unavailable = ProcFSReader.file(proc.root + "/200/stat") else { Issue.record("locked"); return }
        proc.lock("200/fd")
        guard case .unavailable = ProcFSReader.directory(proc.root + "/200/fd") else { Issue.record("locked dir"); return }
    }

    #if os(macOS)
    @Test func pidfdsAreUnsupportedOffLinux() {
        #expect(PidFD.open(getpid()) == .unsupported)
        #expect(PidFD.signal(0, 0) == false)
    }
    #endif
}
