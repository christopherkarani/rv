// libFuzzer harness: the `/proc` text readers behind the secrets gateway's
// Linux peer binding (`ProcFSParse`). Build and run: docs/fuzzing.md.
// In-suite twin: ProcFSFuzzTests, which holds the same properties, so a
// crash file replays there through `violations(_:)`.
import Foundation
@testable import RVIsolation

@_cdecl("LLVMFuzzerTestOneInput")
public func rvFuzzProcFS(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let broken = ProcFSProperties.violations(Array(UnsafeBufferPointer(start: data, count: size)))
    precondition(broken.isEmpty, "\(broken)")
    return 0
}

/// Identical in ProcFSFuzzTests.
enum ProcFSProperties {
    /// SplitMix64 seeded by FNV-1a of the input, so every choice a case
    /// makes beyond its bytes is a function of them.
    struct Mix {
        var state: UInt64

        init(_ bytes: [UInt8]) {
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01B3
            }
            state = hash
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// One input: `[selector][payload]`. The selector (mod 6) picks the
    /// reader: `stat`, `status`, a socket table, `mountinfo`, an io_uring
    /// `fdinfo`, or one `fd` link. Empty means no property was broken.
    static func violations(_ bytes: [UInt8]) -> [String] {
        guard let selector = bytes.first else { return [] }
        let payload = Array(bytes.dropFirst())
        var mix = Mix(bytes)
        switch selector % 6 {
        case 0: return stat(payload, &mix)
        case 1: return status(payload)
        case 2: return sockets(payload, &mix)
        case 3: return mountinfo(payload)
        case 4: return ring(payload)
        default: return link(payload)
        }
    }

    static func utf8(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// What the kernel prints for a name it escapes (`seq_file_path`,
    /// mountinfo): space, tab, newline and backslash as octal.
    static func kernelEscaped(_ bytes: [UInt8]) -> [UInt8] {
        bytes.flatMap { byte -> [UInt8] in
            switch byte {
            case UInt8(ascii: " "): utf8("\\040")
            case UInt8(ascii: "\t"): utf8("\\011")
            case UInt8(ascii: "\n"): utf8("\\012")
            case UInt8(ascii: "\\"): utf8("\\134")
            default: [byte]
            }
        }
    }

    /// `comm` is the process's to choose. Whatever it is, the fields after
    /// it are the kernel's; and a `stat` cut short anywhere is refused.
    static func stat(_ payload: [UInt8], _ mix: inout Mix) -> [String] {
        var broken: [String] = []
        if let parsed = ProcFSParse.stat(payload), ProcFSParse.start(ticks: parsed.startTicks, hz: 100) == nil {
            broken.append("a parsed stat has no start time")
        }
        let comm = Array(payload.prefix(64))
        let expected = ProcFSParse.Stat(
            pid: UInt32(truncatingIfNeeded: mix.next()), state: UInt8(ascii: "S"),
            parent: UInt32(truncatingIfNeeded: mix.next()), group: UInt32(truncatingIfNeeded: mix.next()),
            session: UInt32(truncatingIfNeeded: mix.next()), startTicks: mix.next())
        let tail = ") S \(expected.parent) \(expected.group) \(expected.session) 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 "
            + "\(expected.startTicks) 0 0\n"
        let text = utf8("\(expected.pid) (") + comm + utf8(tail)
        if ProcFSParse.stat(text) != expected { broken.append("comm changed the fields read after it") }
        let cut = 1 + Int(mix.next() % UInt64(text.count - 1))
        if ProcFSParse.stat(Array(text.prefix(cut))) != nil { broken.append("a stat cut at \(cut) of \(text.count) was accepted") }
        return broken
    }

    /// A `Name:` cannot supply the uids: the answer is the kernel's one
    /// `Uid:` line or nothing.
    static func status(_ payload: [UInt8]) -> [String] {
        var broken: [String] = []
        if let raw = ProcFSParse.uids(status: payload), raw.count != 4 { broken.append("uids are not four") }
        let text = utf8("Name:\t") + payload + utf8("\nUmask:\t0022\nUid:\t1001\t1002\t1003\t1004\nGid:\t5\t6\t7\t8\n")
        if let uids = ProcFSParse.uids(status: text), uids != [1001, 1002, 1003, 1004] {
            broken.append("a name supplied the uids \(uids)")
        }
        return broken
    }

    /// The same text reads the same on either byte order but for the
    /// address words; a match is a held row of the connection; row order
    /// does not matter; and one more row can only make a match "cannot
    /// tell", never a different socket.
    static func sockets(_ payload: [UInt8], _ mix: inout Mix) -> [String] {
        var broken: [String] = []
        let little = ProcFSParse.sockets(payload, littleEndian: true)
        let big = ProcFSParse.sockets(payload, littleEndian: false)
        guard let little, let big else {
            if (little == nil) != (big == nil) { broken.append("byte order changed whether the table parses") }
            return broken
        }
        let lines = payload.split(separator: UInt8(ascii: "\n")).count
        if little.count != lines - 1 || big.count != little.count { broken.append("rows are not one per line") }
        for (a, b) in zip(little, big) {
            func swapped(_ address: [UInt8]) -> [UInt8] {
                stride(from: 0, to: address.count, by: 4).flatMap { address[$0..<($0 + 4)].reversed() }
            }
            // A v4-mapped address folds to 4 bytes on one order only; compare the rest.
            let comparable = a.local.address.count == b.local.address.count
                && a.remote.address.count == b.remote.address.count
            if a.local.port != b.local.port || a.remote.port != b.remote.port || a.state != b.state || a.uid != b.uid
                || a.inode != b.inode
                || (comparable && (swapped(a.local.address) != b.local.address
                    || swapped(a.remote.address) != b.remote.address))
            {
                broken.append("byte order changed more than the address words")
            }
        }
        // Ports taken from the table when it has loopback rows, so matches happen.
        let loopback = little.filter { $0.local.address == ProcFSParse.loopback && $0.remote.address == ProcFSParse.loopback }
        let pick = loopback.isEmpty ? nil : loopback[Int(mix.next() % UInt64(loopback.count))]
        let port = pick?.local.port ?? UInt16(truncatingIfNeeded: mix.next())
        let gateway = pick?.remote.port ?? UInt16(truncatingIfNeeded: mix.next())
        let found = ProcFSParse.clientInode(little, port: port, gatewayPort: gateway)
        if let found {
            let client = ProcFSParse.Endpoint(address: ProcFSParse.loopback, port: port)
            let server = ProcFSParse.Endpoint(address: ProcFSParse.loopback, port: gateway)
            let clients = little.filter { $0.local == client && $0.remote == server && $0.inode != 0 }
            let servers = little.filter { $0.local == server && $0.remote == client && $0.inode != 0 }
            if found == 0 || clients.isEmpty || clients.contains(where: { $0.inode != found }) || servers.isEmpty {
                broken.append("a match is not the one held client row beside a gateway row")
            }
        }
        if ProcFSParse.clientInode(little.reversed(), port: port, gatewayPort: gateway) != found {
            broken.append("row order changed the match")
        }
        if let found, let source = little.isEmpty ? nil : little[Int(mix.next() % UInt64(little.count))] {
            var extra = source
            extra.inode = mix.next() % 4 == 0 ? 0 : mix.next() % 100_000
            if mix.next() % 2 == 0 { extra.local = .init(address: ProcFSParse.loopback, port: port) }
            if mix.next() % 2 == 0 { extra.remote = .init(address: ProcFSParse.loopback, port: gateway) }
            let after = ProcFSParse.clientInode(little + [extra], port: port, gatewayPort: gateway)
            if after != nil, after != found { broken.append("an added row changed the match to another socket") }
        }
        return broken
    }

    /// Another mount, wherever it is and whatever it is called, does not
    /// make a `/proc` that hides processes read as one that shows them.
    static func mountinfo(_ payload: [UInt8]) -> [String] {
        var broken: [String] = []
        _ = ProcFSParse.hidesProcesses(mountinfo: payload, mountPoint: "/proc")
        let proc = utf8("22 27 0:21 / /proc rw,relatime shared:5 - proc proc rw,hidepid=invisible\n")
        let name = kernelEscaped(Array(payload.prefix(96)))
        for type in ["tmpfs", "proc"] {
            let other = utf8("99 27 0:55 / /mnt/") + name + utf8(" rw,relatime - \(type) \(type) rw,hidepid=off\n")
            for text in [proc + other, other + proc] where ProcFSParse.hidesProcesses(mountinfo: text, mountPoint: "/proc") != true {
                broken.append("a \(type) mount elsewhere changed what /proc hides")
            }
        }
        return broken
    }

    /// A registered file's name is one entry, and reads as a socket only if
    /// it is one: a path cannot be `socket:[n]`.
    static func ring(_ payload: [UInt8]) -> [String] {
        var broken: [String] = []
        _ = ProcFSParse.ringFiles(fdinfo: payload)
        let name = kernelEscaped(Array(payload.prefix(96)))
        let text = utf8("pos:\t0\nino:\t9\nUserFiles:\t2\n    0: /") + name + utf8("\n    1: socket:[77]\nUserBufs:\t0\n")
        guard let files = ProcFSParse.ringFiles(fdinfo: text) else { return ["a ring with files listed nothing"] }
        if files.count != 2 { broken.append("a file name made \(files.count) entries") }
        if files.compactMap({ ProcFSParse.socketInode(link: $0) }) != [77] { broken.append("a path read as a socket") }
        return broken
    }

    /// Only `socket:[<digits>]` names a socket.
    static func link(_ payload: [UInt8]) -> [String] {
        guard let inode = ProcFSParse.socketInode(link: payload[...]) else { return [] }
        let digits = payload.dropFirst(8).dropLast()
        let shaped = payload.starts(with: utf8("socket:[")) && payload.last == UInt8(ascii: "]") && digits.isEmpty == false
            && digits.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
        return shaped && UInt64(String(decoding: digits, as: UTF8.self)) == inode ? [] : ["a link that is not socket:[n] named inode \(inode)"]
    }
}
