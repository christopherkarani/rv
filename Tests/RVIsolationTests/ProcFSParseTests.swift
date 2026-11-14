import Foundation
import Testing
@testable import RVIsolation

/// Fixture-driven tests for the pure `/proc` readers. They run on every host.
@Suite("ProcFS parsing")
struct ProcFSParseTests {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: stat

    @Test func aRealStatLineYieldsParentGroupSessionAndStart() throws {
        let line = "1 (systemd) S 0 1 1 0 -1 4194560 52017 6113791 107 3082 160 271 31616 9757 20 0 1 0 31 "
            + "22777856 3221 18446744073709551615 1 1 0 0 0 0 671173123 4096 1260 0 0 0 17 3 0 0 0 0 0 0 0 0 0 0 0 0 0\n"
        let stat = try #require(ProcFSParse.stat(bytes(line)))
        #expect(stat == ProcFSParse.Stat(
            pid: 1, state: UInt8(ascii: "S"), parent: 0, group: 1, session: 1, startTicks: 31))
    }

    /// `comm` is the process's own choice: spaces, digits and `)` in it
    /// must not shift the fields read after it.
    @Test(arguments: [
        "a b", "x) S 1 1 1", ") R 999 999 999 0 -1", "((", "evil)", "tab\there",
        "nl\nline", "\u{0600}", "e\u{301}",
    ])
    func commCannotForgeTheFieldsAfterIt(comm: String) throws {
        let line = "4242 (\(comm)) S 77 4242 4000 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 98765 0 0\n"
        let stat = try #require(ProcFSParse.stat(bytes(line)))
        #expect(stat.pid == 4242)
        #expect(stat.parent == 77)
        #expect(stat.group == 4242)
        #expect(stat.session == 4000)
        #expect(stat.startTicks == 98765)
    }

    /// A delimiter that grapheme clustering would fold into a neighbour
    /// (U+0600 is a prepend mark) is still a byte the parser sees.
    @Test func theLastParenthesisIsFoundByByteNotByCharacter() throws {
        let line = "10 (x) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5 0 0\u{0600}) S 3 3 3 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 9 0\n"
        let stat = try #require(ProcFSParse.stat(bytes(line)))
        #expect(stat.parent == 3)
        #expect(stat.startTicks == 9)
    }

    @Test(arguments: [
        "", "1 (x)", "1 (x) S 0 1 1", "x (y) S 0 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5\n",
        "1(x) S 0 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5\n", "1 (x)S 0 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5\n",
        "1 (x) S -1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5\n", "1 (x) SS 0 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5\n",
        "1 (x) S 0 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 99999999999999999999999\n", "1 x) S 0 1 1\n",
    ])
    func malformedStatIsRefused(line: String) {
        #expect(ProcFSParse.stat(bytes(line)) == nil)
    }

    @Test func zombiesAndDeadProcessesHaveExited() throws {
        let zombie = try #require(ProcFSParse.stat(bytes("7 (z) Z 1 7 7 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5 0\n")))
        #expect(ProcFSParse.exited(zombie))
        let running = try #require(ProcFSParse.stat(bytes("7 (z) R 1 7 7 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5 0\n")))
        #expect(ProcFSParse.exited(running) == false)
    }

    @Test func clockTicksSplitIntoSecondsAndMicrosecondsOneToOne() throws {
        #expect(try #require(ProcFSParse.start(ticks: 12_345, hz: 100)) == (123, 450_000))
        #expect(try #require(ProcFSParse.start(ticks: 12_346, hz: 100)) != (123, 450_000))
        #expect(try #require(ProcFSParse.start(ticks: 1_023, hz: 1_024)) == (0, 999_023))
        #expect(ProcFSParse.start(ticks: 1, hz: 0) == nil)
        #expect(ProcFSParse.start(ticks: 1, hz: 2_000_000) == nil)
    }

    // MARK: status

    @Test func theUidLineGivesRealEffectiveSavedAndFilesystem() throws {
        let status = "Name:\tbash\nUmask:\t0022\nState:\tS (sleeping)\nTgid:\t9\nPid:\t9\nPPid:\t1\n"
            + "Uid:\t1000\t0\t1000\t0\nGid:\t1000\t1000\t1000\t1000\n"
        #expect(ProcFSParse.uids(status: bytes(status)) == [1000, 0, 1000, 0])
    }

    @Test(arguments: [
        "Name:\tx\n", "Uid:\t1000\t1000\t1000\n", "Uid:\t1000\t1000\t1000\t1000\nUid:\t0\t0\t0\t0\n",
        "Uid:\t1000\t1000\tx\t1000\n",
    ])
    func aMissingDuplicatedOrMalformedUidLineIsRefused(status: String) {
        #expect(ProcFSParse.uids(status: bytes(status)) == nil)
    }

    // MARK: fd links

    @Test func onlySocketLinksNameAnInode() {
        #expect(ProcFSParse.socketInode(link: "socket:[123456]") == 123_456)
        #expect(ProcFSParse.socketInode(link: "socket:[]") == nil)
        #expect(ProcFSParse.socketInode(link: "socket:[12x]") == nil)
        #expect(ProcFSParse.socketInode(link: "pipe:[123456]") == nil)
        #expect(ProcFSParse.socketInode(link: "/tmp/socket:[123456]") == nil)
        #expect(ProcFSParse.socketInode(link: "anon_inode:[eventpoll]") == nil)
        #expect(ProcFSParse.socketInode(link: "socket:[123456") == nil)
    }

    // MARK: net/tcp

    static let header = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"

    static func row(_ slot: Int, _ local: String, _ remote: String, state: String = "01", uid: Int = 1000, inode: Int)
        -> String
    {
        "  \(slot): \(local) \(remote) \(state) 00000000:00000000 00:00000000 00000000  \(uid)        0 \(inode) 1 "
            + "0000000000000000 20 4 30 10 -1\n"
    }

    @Test func littleEndianIPv4RowsDecodeToLoopbackAndPorts() throws {
        let text = Self.header
            + Self.row(0, "0100007F:1F90", "00000000:0000", state: "0A", inode: 10)
            + Self.row(1, "0100007F:C350", "0100007F:1F90", inode: 2222)
        let rows = try #require(ProcFSParse.sockets(bytes(text), littleEndian: true))
        #expect(rows.count == 2)
        #expect(rows[0].state == 0x0A)
        #expect(rows[1] == ProcFSParse.SocketRow(
            local: .init(address: [127, 0, 0, 1], port: 50_000), remote: .init(address: [127, 0, 0, 1], port: 8080),
            state: 1, uid: 1000, inode: 2222))
    }

    @Test func bigEndianHostsPrintTheSameAddressTheOtherWayRound() throws {
        let text = Self.header + Self.row(0, "7F000001:C350", "7F000001:1F90", inode: 7)
        let rows = try #require(ProcFSParse.sockets(bytes(text), littleEndian: false))
        #expect(rows.first?.local.address == [127, 0, 0, 1])
        let wrong = try #require(ProcFSParse.sockets(bytes(text), littleEndian: true))
        #expect(wrong.first?.local.address == [1, 0, 0, 127])
    }

    /// A dual-stack client socket shows in `tcp6` with v4-mapped addresses.
    @Test func v4MappedIPv6FoldsToIPv4AndPlainIPv6DoesNot() throws {
        let mapped = "0000000000000000FFFF00000100007F"
        let loopback6 = "00000000000000000000000001000000"
        let text = Self.header
            + Self.row(0, "\(mapped):C350", "\(mapped):1F90", inode: 31)
            + Self.row(1, "\(loopback6):C350", "\(loopback6):1F90", inode: 32)
        let rows = try #require(ProcFSParse.sockets(bytes(text), littleEndian: true))
        #expect(rows[0].local.address == [127, 0, 0, 1])
        #expect(rows[0].remote == .init(address: [127, 0, 0, 1], port: 8080))
        #expect(rows[1].local.address == Array(repeating: 0, count: 15) + [1])
        let bigEndian = Self.header + Self.row(0, "00000000000000000000FFFF7F000001:C350", "\(mapped):1F90", inode: 1)
        #expect(try #require(ProcFSParse.sockets(bytes(bigEndian), littleEndian: false)).first?.local.address
            == [127, 0, 0, 1])
    }

    @Test func anEmptyTableIsJustTheHeader() {
        #expect(ProcFSParse.sockets(bytes(Self.header)) == [])
    }

    /// Typed here, not inline in `@Test`: the macro expansion of a literal
    /// this long does not type-check in reasonable time on Linux.
    static let malformedTables: [String] = [
        "",
        "  sl  local_address\n" + "garbage\n",
        String(header.dropLast()),
        header + String(row(0, "0100007F:C350", "0100007F:1F90", inode: 1).dropLast()),
        header + row(0, "0100007F:C35", "0100007F:1F90", inode: 1),
        header + row(0, "0100007G:C350", "0100007F:1F90", inode: 1),
        header + row(0, "0100007F:C350", "0100007F:1F90", state: "1", inode: 1),
        header + row(0, "0100007F:C350", "0100007F:1F90", inode: 1).replacingOccurrences(of: " 1000 ", with: " -1 "),
        header + "   0: 0100007F:C350 0100007F:1F90 01\n",
        row(0, "0100007F:C350", "0100007F:1F90", inode: 1),
    ]

    @Test(arguments: malformedTables)
    func truncatedOrMalformedTablesAreRefused(text: String) {
        #expect(ProcFSParse.sockets(bytes(text), littleEndian: true) == nil)
    }

    // MARK: matching a connection

    private func rows(_ entries: [(String, String, Int)]) throws -> [ProcFSParse.SocketRow] {
        let text = Self.header + entries.enumerated().map { Self.row($0.offset, $0.element.0, $0.element.1, inode: $0.element.2) }
            .joined()
        return try #require(ProcFSParse.sockets(bytes(text), littleEndian: true))
    }

    private let gatewayEnd = ("0100007F:1F90", "0100007F:C350", 1111)
    private let clientEnd = ("0100007F:C350", "0100007F:1F90", 2222)

    @Test func theClientEndIsFoundBesideTheGatewaysOwnEnd() throws {
        #expect(ProcFSParse.clientInode(try rows([gatewayEnd, clientEnd]), port: 50_000, gatewayPort: 8080) == 2222)
        // The mapped client end of the same connection.
        let mapped = ("0000000000000000FFFF00000100007F:C350", "0000000000000000FFFF00000100007F:1F90", 2222)
        let text = Self.header + Self.row(0, gatewayEnd.0, gatewayEnd.1, inode: 1111)
        let six = Self.header + Self.row(0, mapped.0, mapped.1, inode: 2222)
        let both = try #require(ProcFSParse.sockets(bytes(text), littleEndian: true))
            + (try #require(ProcFSParse.sockets(bytes(six), littleEndian: true)))
        #expect(ProcFSParse.clientInode(both, port: 50_000, gatewayPort: 8080) == 2222)
    }

    /// Without the gateway's own end the rows are not from its namespace.
    @Test func noGatewayEndMeansTheTableCannotBeTrusted() throws {
        #expect(ProcFSParse.clientInode(try rows([clientEnd]), port: 50_000, gatewayPort: 8080) == nil)
    }

    /// An inode-0 client row (time-wait, orphaned) is a socket no process
    /// holds; nothing to attribute.
    @Test func aClientEndNoProcessHoldsIsNotAnAnswer() throws {
        #expect(ProcFSParse.clientInode(
            try rows([gatewayEnd, ("0100007F:C350", "0100007F:1F90", 0)]), port: 50_000, gatewayPort: 8080) == nil)
        #expect(ProcFSParse.clientInode(try rows([gatewayEnd]), port: 50_000, gatewayPort: 8080) == nil)
    }

    @Test func twoHeldClientEndsAreAmbiguousButARepeatedRowIsNot() throws {
        let other = ("0100007F:C350", "0100007F:1F90", 3333)
        #expect(ProcFSParse.clientInode(try rows([gatewayEnd, clientEnd, other]), port: 50_000, gatewayPort: 8080) == nil)
        // A read that saw one row twice (the table moved under it).
        #expect(ProcFSParse.clientInode(try rows([gatewayEnd, clientEnd, clientEnd]), port: 50_000, gatewayPort: 8080)
            == 2222)
    }

    @Test func otherAddressesAndPortsDoNotMatch() throws {
        let elsewhere = ("0200007F:C350", "0100007F:1F90", 4444)
        let otherPort = ("0100007F:C351", "0100007F:1F90", 5555)
        #expect(ProcFSParse.clientInode(try rows([gatewayEnd, elsewhere, otherPort]), port: 50_000, gatewayPort: 8080)
            == nil)
    }

    /// A self-connected socket (client port equals gateway port) makes both
    /// ends look alike: not an answer.
    @Test func aConnectionWhoseEndsLookAlikeIsNotAnAnswer() throws {
        let same = ("0100007F:1F90", "0100007F:1F90", 6666)
        let same2 = ("0100007F:1F90", "0100007F:1F90", 7777)
        #expect(ProcFSParse.clientInode(try rows([same, same2]), port: 8080, gatewayPort: 8080) == nil)
    }

    // MARK: mountinfo

    static let mounts = """
        22 28 0:21 / /sys rw,nosuid,nodev,noexec,relatime shared:7 - sysfs sysfs rw
        23 28 0:22 / /proc rw,nosuid,nodev,noexec,relatime shared:13 - proc proc rw
        28 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw

        """

    @Test func aDefaultProcShowsEveryProcess() {
        #expect(ProcFSParse.hidesProcesses(mountinfo: bytes(Self.mounts), mountPoint: "/proc") == false)
    }

    @Test(arguments: ["hidepid=2", "hidepid=invisible", "hidepid=1", "hidepid=noaccess", "hidepid=4", "hidepid=ptraceable"])
    func hidepidHidesProcesses(option: String) {
        let superOptions = Self.mounts.replacingOccurrences(of: "- proc proc rw", with: "- proc proc rw,\(option)")
        #expect(ProcFSParse.hidesProcesses(mountinfo: bytes(superOptions), mountPoint: "/proc") == true)
        let mountOptions = Self.mounts.replacingOccurrences(
            of: "/proc rw,nosuid", with: "/proc rw,\(option),nosuid")
        #expect(ProcFSParse.hidesProcesses(mountinfo: bytes(mountOptions), mountPoint: "/proc") == true)
    }

    @Test func hidepidZeroOrOffShowsEveryProcess() {
        for option in ["hidepid=0", "hidepid=off"] {
            let text = Self.mounts.replacingOccurrences(of: "- proc proc rw", with: "- proc proc rw,\(option)")
            #expect(ProcFSParse.hidesProcesses(mountinfo: bytes(text), mountPoint: "/proc") == false)
        }
    }

    /// A `proc` mounted over another hides what was under it: the last line wins.
    @Test func theLastMountOnThePointIsTheOneInEffect() {
        let stacked = Self.mounts + "40 23 0:30 / /proc rw,relatime - proc proc rw,hidepid=invisible\n"
        #expect(ProcFSParse.hidesProcesses(mountinfo: bytes(stacked), mountPoint: "/proc") == true)
        let tmpfs = Self.mounts + "41 23 0:31 / /proc rw - tmpfs tmpfs rw\n"
        #expect(ProcFSParse.hidesProcesses(mountinfo: bytes(tmpfs), mountPoint: "/proc") == nil)
    }

    @Test func noProcAtThePointOrAMalformedLineCannotTell() {
        #expect(ProcFSParse.hidesProcesses(mountinfo: bytes(Self.mounts), mountPoint: "/elsewhere") == nil)
        #expect(ProcFSParse.hidesProcesses(mountinfo: bytes("23 28 0:22 / /proc rw proc proc rw\n"), mountPoint: "/proc")
            == nil)
        let spaced = "23 28 0:22 / /my\\040proc rw - proc proc rw\n"
        #expect(ProcFSParse.hidesProcesses(mountinfo: bytes(spaced), mountPoint: "/my proc") == false)
    }

    // MARK: binary identity

    @Test func aLinuxExecutableMustBeThePinnedFileNotJustItsPath() throws {
        let pin = try GatewayBinaryPin.pin("/bin/sh").get()
        #expect(pin.matches(ProcessExecutable.file(path: pin.path, running: pin)))
        #expect(pin.matches(ProcessExecutable.path(pin.path)))
        var other = pin
        other.inode &+= 1
        #expect(pin.matches(ProcessExecutable.file(path: pin.path, running: other)) == false)
        other = pin
        other.changedNanoseconds &+= 1
        #expect(pin.matches(ProcessExecutable.file(path: pin.path, running: other)) == false)
        #expect(pin.matches(ProcessExecutable.file(path: pin.path + " (deleted)", running: pin)) == false)
        #expect(pin.matches(ProcessExecutable.file(path: "/bin/other", running: pin)) == false)
    }
}
