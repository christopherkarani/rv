// Test probe for RVMCPTests, run as a child. Not shipped.
//
// `rv-mcp-probe signals [INT] [TERM] [HUP]` sets the named signals to the
// default, then installs `MCPShutdownSignals`, which changes real
// signal dispositions (never done in the shared test process). It prints the
// dispositions it inherited and installed, spawns `report` through
// Foundation `Process` as serve spawns a plain server, sends itself SIGTERM,
// then cancels and prints the restored dispositions.
// `rv-mcp-probe report` prints this process's dispositions.
// `rv-mcp-probe procargs <pid|self>` reads `pid`'s arguments and environment
// through `sysctl` `KERN_PROCARGS2`, as a caged server could, and prints what
// it got back: never the values, only counts and whether `HOME=` was there.
// `rv-mcp-probe procargs-bytes <hex>` runs the same parse over a given buffer.
import Darwin
import Foundation
import RVMCP
import Synchronization

private final class Count: Sendable {
    let value = Mutex(0)
}

private func dispositions() -> String {
    let names: [(Int32, String)] = [(SIGINT, "INT"), (SIGTERM, "TERM"), (SIGHUP, "HUP")]
    let ignore = unsafeBitCast(SIG_IGN as sig_t?, to: Int.self)
    return names.map { number, name in
        var current = sigaction()
        guard sigaction(number, nil, &current) == 0 else { return "\(name)=unreadable" }
        let handler = unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
        let shown = handler == 0 ? "default" : handler == ignore ? "ignore" : "handler"
        return "\(name)=\(shown)"
    }.joined(separator: " ")
}

private func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

private func catchSignals() -> Int32 {
    say("inherited " + dispositions())
    let signals = MCPShutdownSignals(MCPShutdownSignals.handled, catching: true)
    let heard = Count()
    signals.forward { heard.value.withLock { $0 += 1 } }
    say("installed " + dispositions())

    let child = Process()
    child.executableURL = Bundle.main.executableURL
    child.arguments = ["report"]
    let output = Pipe()
    child.standardOutput = output
    do {
        try child.run()
    } catch {
        say("child unstartable")
        return 1
    }
    child.waitUntilExit()
    let reported = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    say("child " + reported.trimmingCharacters(in: .whitespacesAndNewlines))

    kill(getpid(), SIGTERM)
    let deadline = Date().addingTimeInterval(15)
    while heard.value.withLock({ $0 }) == 0, Date() < deadline { usleep(10_000) }
    say("heard \(heard.value.withLock { $0 }) first \(signals.first.map { String($0) } ?? "none")")

    signals.cancel()
    say("restored " + dispositions())
    return 0
}

/// `KERN_PROCARGS2`: argc, the exec path and its NUL, NUL padding up to the
/// next 8-byte boundary after the argc word, exactly argc NUL-terminated
/// arguments (any of them may be empty, `argv[0]` too), then whatever
/// environment the kernel shows this caller. The arguments start at that
/// boundary, never at the first non-NUL byte, which an empty `argv[0]`
/// would push one string on. No exec path terminator, padding that is not
/// NUL, or fewer than argc terminated arguments is a failed read, never
/// "no environment". Every non-empty string after the arguments counts, so
/// nothing the kernel returned is skipped. The 8-byte padding was measured
/// on macOS 27 (exec paths of every length mod 8, `argv[0]` empty or not);
/// were it smaller, a non-empty `argv[0]` would land in it and fail the read.
private func procargs(_ pid: pid_t) -> String {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    var size = buffer.count
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return "failed errno=\(errno)" }
    return parseProcargs(Array(buffer.prefix(size)))
}

/// The parse alone, over bytes in `KERN_PROCARGS2` layout.
private func parseProcargs(_ data: [UInt8]) -> String {
    guard data.count >= 4 else { return "failed short" }
    let argc = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
    guard argc >= 0 else { return "failed argc=\(argc)" }
    var index = 4
    while index < data.count, data[index] != 0 { index += 1 }
    guard index < data.count else { return "failed no exec path" }
    let padded = index + 1
    let arguments = 4 + (padded - 4 + 7) / 8 * 8
    guard arguments <= data.count, data[padded..<arguments].allSatisfy({ $0 == 0 }) else {
        return "failed padding"
    }
    index = arguments
    for _ in 0..<argc {
        while index < data.count, data[index] != 0 { index += 1 }
        guard index < data.count else { return "failed truncated argc=\(argc)" }
        index += 1
    }
    let rest = data[index...].split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    let home = rest.contains { $0.hasPrefix("HOME=") }
    return "ok argc=\(argc) strings=\(rest.count) home=\(home ? "yes" : "no")"
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first ?? "" {
case "report":
    say(dispositions())
    exit(0)
case "signals":
    // Signals named after `signals` are set to the default first, in this
    // child only, so the test does not depend on what its runner ignores.
    let names: [String: Int32] = ["INT": SIGINT, "TERM": SIGTERM, "HUP": SIGHUP]
    for name in arguments.dropFirst() {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&action.sa_mask)
        guard let number = names[name], sigaction(number, &action, nil) == 0 else {
            say("usage: rv-mcp-probe signals [INT] [TERM] [HUP]")
            exit(2)
        }
    }
    exit(catchSignals())
case "procargs":
    // Arguments after the pid are ignored: they exist so a test can read
    // its own probe's (`self`) argument list with empty entries in it.
    guard arguments.count >= 2, let pid = arguments[1] == "self" ? Optional(getpid()) : pid_t(arguments[1]) else {
        say("usage: rv-mcp-probe procargs <pid|self> [ignored...]")
        exit(2)
    }
    say(procargs(pid))
    exit(0)
case "procargs-bytes":
    // A hand-built buffer, hex encoded, for layouts no real process makes.
    let hex = arguments.count == 2 ? Array(arguments[1].utf8) : []
    let bytes = stride(from: 0, to: hex.count - 1, by: 2).compactMap {
        UInt8(String(decoding: hex[$0...($0 + 1)], as: UTF8.self), radix: 16)
    }
    guard arguments.count == 2, hex.count % 2 == 0, bytes.count * 2 == hex.count else {
        say("usage: rv-mcp-probe procargs-bytes <hex>")
        exit(2)
    }
    say(parseProcargs(bytes))
    exit(0)
default:
    say("usage: rv-mcp-probe signals [INT] [TERM] [HUP] | report | procargs <pid|self> [ignored...] | procargs-bytes <hex>")
    exit(2)
}
