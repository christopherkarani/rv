/// Pure readers for the Linux `/proc` text the secrets gateway's runtime
/// binding interprets. Every function takes the file's bytes and returns nil
/// for anything it does not fully understand, so a caller can fail closed.
/// They work on bytes, not `Character`s: a process names itself (`comm`), and
/// grapheme clustering could otherwise merge a delimiter into its name.
enum ProcFSParse {
    /// `/proc/<pid>/stat`: the fields the binding needs.
    struct Stat: Equatable, Sendable {
        var pid: UInt32
        /// Field 3: `R`, `S`, `Z` (exited, not yet reaped), ...
        var state: UInt8
        var parent: UInt32
        var group: UInt32
        var session: UInt32
        /// Field 22: clock ticks after boot.
        var startTicks: UInt64
    }

    /// `comm` (field 2) may hold spaces, digits and `)`, so the fields after
    /// it are read from the last `)`: nothing the kernel prints after it can
    /// contain one.
    static func stat(_ bytes: [UInt8]) -> Stat? {
        guard let open = bytes.firstIndex(of: UInt8(ascii: "(")), open > 1,
            bytes[open - 1] == UInt8(ascii: " "),
            let close = bytes.lastIndex(of: UInt8(ascii: ")")), close > open,
            let pid: UInt32 = decimal(bytes[..<(open - 1)])
        else { return nil }
        let rest = bytes[(close + 1)...]
        guard rest.first == UInt8(ascii: " ") else { return nil }
        let fields = rest.split(whereSeparator: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\n") })
        // fields[0] is field 3 (state), so field n is fields[n - 3].
        guard fields.count >= 20, fields[0].count == 1,
            let parent: UInt32 = decimal(fields[1]),
            let group: UInt32 = decimal(fields[2]),
            let session: UInt32 = decimal(fields[3]),
            let start: UInt64 = decimal(fields[19])
        else { return nil }
        return Stat(
            pid: pid, state: fields[0][fields[0].startIndex], parent: parent, group: group, session: session,
            startTicks: start)
    }

    /// A zombie (`Z`) or dead (`X`) process has exited: it holds no
    /// descriptors and runs nothing, and libproc does not report one.
    static func exited(_ stat: Stat) -> Bool {
        stat.state == UInt8(ascii: "Z") || stat.state == UInt8(ascii: "X")
    }

    /// Clock ticks after boot as seconds and microseconds, the shape
    /// `ProcessGroupFact` records. One-to-one for any `hz` up to a million,
    /// so equal starts stay equal and order is kept.
    static func start(ticks: UInt64, hz: UInt64) -> (seconds: UInt64, microseconds: UInt64)? {
        guard hz > 0, hz <= 1_000_000 else { return nil }
        return (ticks / hz, (ticks % hz) * 1_000_000 / hz)
    }

    /// The real, effective, saved and filesystem uids from the one `Uid:`
    /// line of `/proc/<pid>/status`. Nil when there is not exactly one.
    static func uids(status bytes: [UInt8]) -> [UInt32]? {
        let tag = Array("Uid:".utf8)
        let lines = bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .filter { $0.starts(with: tag) }
        guard lines.count == 1, let line = lines.first else { return nil }
        let values = line.dropFirst(tag.count)
            .split(whereSeparator: { $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: " ") })
            .map { decimal($0) as UInt32? }
        guard values.count == 4 else { return nil }
        let uids = values.compactMap { $0 }
        return uids.count == 4 ? uids : nil
    }

    /// The inode a `/proc/<pid>/fd/<n>` link names when it is a socket.
    static func socketInode(link: String) -> UInt64? {
        socketInode(link: Array(link.utf8)[...])
    }

    static func socketInode(link bytes: ArraySlice<UInt8>) -> UInt64? {
        let prefix = Array("socket:[".utf8)
        guard bytes.count > prefix.count + 1, bytes.starts(with: prefix), bytes.last == UInt8(ascii: "]") else {
            return nil
        }
        return decimal(bytes.dropFirst(prefix.count).dropLast())
    }

    /// What `/proc/<pid>/fd/<n>` reads as for an io_uring instance.
    static let ringLink = "anon_inode:[io_uring]"

    /// The files registered with an io_uring instance
    /// (`IORING_REGISTER_FILES`, direct descriptors), from its
    /// `/proc/<pid>/fdinfo/<n>`: the entries under `UserFiles:`, each
    /// `<slot>: <name>` with the name as an `fd` link would read. A process
    /// can register a socket and close its descriptor: the ring then holds
    /// the socket and no `fd` link names it. Nil when there is no
    /// `UserFiles:` line (the kernel omits it while the ring is busy) or
    /// its count is not a number.
    static func ringFiles(fdinfo bytes: [UInt8]) -> [ArraySlice<UInt8>]? {
        let tag = Array("UserFiles:".utf8)
        let lines = bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        guard let header = lines.firstIndex(where: { $0.starts(with: tag) }),
            let count = fields(lines[header].dropFirst(tag.count)).first, (decimal(count) as UInt32?) != nil
        else { return nil }
        var names: [ArraySlice<UInt8>] = []
        for line in lines[(header + 1)...] {
            // `%5u: name`; anything else ends the list.
            let entry = line.drop(while: { $0 == UInt8(ascii: " ") })
            guard let colon = entry.firstIndex(of: UInt8(ascii: ":")), (decimal(entry[..<colon]) as UInt32?) != nil,
                entry[colon...].starts(with: Array(": ".utf8))
            else { break }
            names.append(entry[(colon + 2)...])
        }
        return names
    }

    /// What `/proc/<pid>/exe` reads as once the file the process runs has
    /// been unlinked (replaced, upgraded, deleted).
    static let deletedSuffix = " (deleted)"

    // MARK: - /proc/net/tcp and /proc/net/tcp6

    struct Endpoint: Equatable, Sendable {
        /// Network byte order. A v4-mapped IPv6 address is folded to its 4
        /// IPv4 bytes, so a dual-stack client socket compares as IPv4.
        var address: [UInt8]
        var port: UInt16
    }

    struct SocketRow: Equatable, Sendable {
        var local: Endpoint
        var remote: Endpoint
        var state: UInt8
        var uid: UInt32
        /// 0 for a socket no process holds (`TIME_WAIT`, orphaned).
        var inode: UInt64
    }

    /// Every row of `/proc/net/tcp` or `/proc/net/tcp6`. The kernel prints
    /// each address as 32-bit words in the host's byte order (`%08X` of a
    /// big-endian word), so `littleEndian` says how to read them. Nil when
    /// the header is missing, any row is malformed, or the text does not
    /// end in a newline (a truncated read).
    static func sockets(_ bytes: [UInt8], littleEndian: Bool = hostIsLittleEndian) -> [SocketRow]? {
        guard bytes.last == UInt8(ascii: "\n") else { return nil }
        let lines = bytes.split(separator: UInt8(ascii: "\n"))
        guard let header = lines.first, fields(header).first.map({ Array($0) == Array("sl".utf8) }) == true else {
            return nil
        }
        var rows: [SocketRow] = []
        for line in lines.dropFirst() {
            guard let row = socketRow(line, littleEndian: littleEndian) else { return nil }
            rows.append(row)
        }
        return rows
    }

    private static func socketRow(_ line: ArraySlice<UInt8>, littleEndian: Bool) -> SocketRow? {
        let columns = fields(line)
        // sl local remote st tx:rx tr:when retrnsmt uid timeout inode ...
        guard columns.count >= 10, columns[0].last == UInt8(ascii: ":"),
            let local = endpoint(columns[1], littleEndian: littleEndian),
            let remote = endpoint(columns[2], littleEndian: littleEndian),
            columns[3].count == 2, let state: UInt8 = hexadecimal(columns[3]),
            let uid: UInt32 = decimal(columns[7]),
            let inode: UInt64 = decimal(columns[9])
        else { return nil }
        return SocketRow(local: local, remote: remote, state: state, uid: uid, inode: inode)
    }

    private static func endpoint(_ column: ArraySlice<UInt8>, littleEndian: Bool) -> Endpoint? {
        let parts = column.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 4, let port: UInt16 = hexadecimal(parts[1]),
            parts[0].count == 8 || parts[0].count == 32
        else { return nil }
        var address: [UInt8] = []
        var start = parts[0].startIndex
        while start < parts[0].endIndex {
            guard let word: UInt32 = hexadecimal(parts[0][start..<(start + 8)]) else { return nil }
            let bytes = (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) }
            address += littleEndian ? bytes : bytes.reversed()
            start += 8
        }
        let mapped: [UInt8] = Array(repeating: 0, count: 10) + [0xFF, 0xFF]
        if address.count == 16, address.starts(with: mapped) { address = Array(address.suffix(4)) }
        return Endpoint(address: address, port: port)
    }

    static let loopback: [UInt8] = [127, 0, 0, 1]

    /// The inode of the client socket of `peer`'s connection, from the rows
    /// of both tables. The gateway's own end (gateway port to client port)
    /// must be in the same rows: that proves they come from the gateway's
    /// network namespace (each reader sees only its own). Nil, so the caller
    /// cannot tell, unless exactly one held socket (inode not 0) is each
    /// end. A connected loopback 4-tuple is unique in a namespace while the
    /// gateway holds its end, so two held client rows mean the read is not
    /// to be trusted. A client row with inode 0 is a socket no process holds
    /// any more: nothing to attribute.
    static func clientInode(_ rows: [SocketRow], port: UInt16, gatewayPort: UInt16) -> UInt64? {
        func ends(local: UInt16, remote: UInt16) -> Set<UInt64> {
            Set(rows.lazy.filter {
                $0.inode != 0 && $0.local == Endpoint(address: loopback, port: local)
                    && $0.remote == Endpoint(address: loopback, port: remote)
            }.map(\.inode))
        }
        let gateway = ends(local: gatewayPort, remote: port)
        let client = ends(local: port, remote: gatewayPort)
        guard gateway.count == 1, client.count == 1, client != gateway else { return nil }
        return client.first
    }

    // MARK: - /proc/self/mountinfo

    /// Whether the `proc` mounted at `mountPoint` hides other processes
    /// (`hidepid=` anything but `0`/`off`). Then a descendant running as
    /// another user (a setuid child) cannot be seen, and an empty scan
    /// proves nothing. Nil when no `proc` is mounted there or the line is
    /// malformed. The last mount on that point is the one in effect.
    static func hidesProcesses(mountinfo bytes: [UInt8], mountPoint: String) -> Bool? {
        let wanted = Array(escapedMountPath(mountPoint).utf8)
        guard let line = bytes.split(separator: UInt8(ascii: "\n")).last(where: {
            let columns = fields($0)
            return columns.count >= 5 && Array(columns[4]) == wanted
        }) else { return nil }
        let columns = fields(line)
        guard let separator = columns.firstIndex(where: { Array($0) == [UInt8(ascii: "-")] }),
            separator >= 6, columns.count > separator + 3,
            Array(columns[separator + 1]) == Array("proc".utf8)
        else { return nil }
        let hidepid = Array("hidepid=".utf8)
        // Per-mount options (Linux 5.8+) and older global ones: read both lists.
        let options = (columns[5].split(separator: UInt8(ascii: ","))
            + columns[separator + 3].split(separator: UInt8(ascii: ",")))
        return options.contains { option in
            guard option.starts(with: hidepid) else { return false }
            let value = Array(option.dropFirst(hidepid.count))
            return value != Array("0".utf8) && value != Array("off".utf8)
        }
    }

    /// mountinfo escapes space, tab, newline and backslash as octal.
    private static func escapedMountPath(_ path: String) -> String {
        var escaped = ""
        for scalar in path.unicodeScalars {
            switch scalar {
            case " ": escaped += "\\040"
            case "\t": escaped += "\\011"
            case "\n": escaped += "\\012"
            case "\\": escaped += "\\134"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    // MARK: - Numbers

    static var hostIsLittleEndian: Bool { UInt16(1).littleEndian == 1 }

    private static func fields(_ line: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        line.split(whereSeparator: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") })
    }

    static func decimal<T: FixedWidthInteger & UnsignedInteger>(_ digits: ArraySlice<UInt8>) -> T? {
        guard digits.isEmpty == false, digits.count <= 20 else { return nil }
        var value: T = 0
        for digit in digits {
            guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") else { return nil }
            let (shifted, overflowA) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflowB) = shifted.addingReportingOverflow(T(digit - UInt8(ascii: "0")))
            guard overflowA == false, overflowB == false else { return nil }
            value = sum
        }
        return value
    }

    static func hexadecimal<T: FixedWidthInteger & UnsignedInteger>(_ digits: ArraySlice<UInt8>) -> T? {
        guard digits.isEmpty == false, digits.count <= T.bitWidth / 4 else { return nil }
        var value: T = 0
        for digit in digits {
            let nibble: UInt8
            switch digit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = digit - UInt8(ascii: "0")
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibble = digit - UInt8(ascii: "A") + 10
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = digit - UInt8(ascii: "a") + 10
            default: return nil
            }
            value = value << 4 | T(nibble)
        }
        return value
    }
}
