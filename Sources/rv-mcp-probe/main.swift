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
// `rv-mcp-probe hold` reads its stdin until it ends, then exits: a process
// whose arguments and environment stay there to read for as long as the
// test holds that stdin open.
// `rv-mcp-probe unix-connect <path>` connects to the Unix-domain stream
// socket at `path` and writes one byte, printing whether it connected or
// the errno.
// `rv-mcp-probe unix-dgram <path>` connects one Unix-domain datagram socket
// to `path` and sends one byte to it from another with `sendto`, printing
// what each did.
// `rv-mcp-probe peerinfo <pid>` asks `proc_pidfdinfo` about `pid`'s fd 0
// and `proc_pid_rusage` about `pid`, printing whether each answered.
// `rv-mcp-probe remote-starved <url>` fills GCD's shared global pool with
// work that never ends, then sends `initialize` to the MCP server at `url`
// through `MCPRemoteUpstream` and a GET through the secrets gateway's
// upstream transport, and prints how long each took to answer ("none"
// after 10 s).
// `rv-mcp-probe stderr <bytes> [interrupted|closed|closed-default]` ignores
// SIGPIPE as serve does (`closed-default` sets it to the default instead,
// as during planning), then writes one line of `bytes` x's through the
// gateway's stderr writer: `interrupted` under a 1 ms SIGALRM without
// SA_RESTART, `closed` and `closed-default` to a stderr whose read end the
// probe closed itself, so no other process can hold it open. Prints
// "returned" once the write returns.
// `rv-mcp-probe pipe-disposition <file>` writes `PIPE=<disposition>` to `file`.
// `rv-mcp-probe serve <directory> <script> [INT] [TERM] [HUP] [CHLD-ignored]`
// sets the named signals to the default (and SIGCHLD to ignored), then
// serves one plain stdio server, `python3 -u <script> <directory>/server`,
// with serve's own signal wiring and this probe's stdin and stdout as the
// client. It writes SIGCHLD's disposition once the signals are set up to
// `<directory>/chld`, one `<tool> <outcome>` line per audit record to
// `<directory>/audit`, and exits as serve would.
import Darwin
import Foundation
import RVIsolation
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

/// Milliseconds since `start`, or "none" when `answered` timed out.
private func elapsed(_ start: Date, _ answered: Bool) -> String {
    answered ? String(Int(Date().timeIntervalSince(start) * 1000)) : "none"
}

/// GCD hands out at most `kern.wq_max_constrained_threads` (64-70) threads
/// for the global queues; 256 blocked items take every one of them.
private func remoteWhileStarved(_ url: URL) -> Int32 {
    let held = DispatchSemaphore(value: 0)
    for _ in 0..<256 { DispatchQueue.global().async { held.wait() } }
    usleep(500_000)

    let answered = DispatchSemaphore(value: 0)
    let upstream = MCPRemoteUpstream(
        launch: MCPRemoteLaunch(server: "starved", url: url),
        deliver: { _ in answered.signal() }, exited: {}, log: { _ in })
    let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}"#
    guard let message = try? JSONValue.parse(initialize) else { return 1 }
    var start = Date()
    upstream.start()
    upstream.send(message)
    say("upstream " + elapsed(start, answered.wait(timeout: .now() + 10) == .success))


    // The secrets gateway's upstream transport, as a gateway connection
    // handler calls it: blocking, on a thread of its own.
    let sink = GatewaySink()
    let transport = SecretUpstreamTransport.urlSession
    let request = SecretUpstreamRequest(method: "GET", url: url, headers: [], body: Data())
    start = Date()
    Thread.detachNewThread { transport.send(request, sink) }
    let finished = sink.done.wait(timeout: .now() + 10) == .success
    let gatewayStatus = sink.status.withLock { $0 }
    say("gateway " + elapsed(start, finished) + " status \(gatewayStatus.map { String($0) } ?? "none")")
    // The held work never ends; exit rather than return to it.
    exit(0)
}

private final class GatewaySink: SecretResponseSink, Sendable {
    let done = DispatchSemaphore(value: 0)
    let status = Mutex<Int?>(nil)

    func head(status: Int, headers: [(name: String, value: String)]) { self.status.withLock { $0 = status } }
    func body(_ data: Data) -> Bool { true }
    func finish() { done.signal() }
    func fail(_ reason: String) { done.signal() }
}

/// `pipe-disposition`: what this process got for SIGPIPE.
private func pipeDisposition() -> String {
    var current = sigaction()
    guard sigaction(SIGPIPE, nil, &current) == 0 else { return "PIPE=unreadable" }
    let handler = unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
    let ignore = unsafeBitCast(SIG_IGN as sig_t?, to: Int.self)
    return "PIPE=" + (handler == 0 ? "default" : handler == ignore ? "ignore" : "handler")
}

/// What signal `number` is set to now: `default`, `ignore` or `handler`.
private func disposition(_ number: Int32) -> String {
    var current = sigaction()
    guard sigaction(number, nil, &current) == 0 else { return "unreadable" }
    let handler = unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
    let ignore = unsafeBitCast(SIG_IGN as sig_t?, to: Int.self)
    return handler == 0 ? "default" : handler == ignore ? "ignore" : "handler"
}

private func append(_ line: String, to path: String) {
    guard let handle = FileHandle(forWritingAtPath: path) ?? {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }() else { return }
    handle.seekToEndOfFile()
    handle.write(Data((line + "\n").utf8))
    try? handle.close()
}

private func outcomeName(_ outcome: MCPCallRecord.Outcome) -> String {
    switch outcome {
    case .ran: "ran"
    case .interrupted: "interrupted"
    case .forwarding: "forwarding"
    default: "\(outcome)"
    }
}

/// `serve`: the signal wiring of `rv mcp serve` around one plain server.
private func serveUnderSignals(_ directory: String, _ script: String, _ flags: ArraySlice<String>) -> Int32 {
    let names: [String: Int32] = ["INT": SIGINT, "TERM": SIGTERM, "HUP": SIGHUP]
    for flag in flags {
        if flag == "CHLD-ignored" {
            signal(SIGCHLD, SIG_IGN)
            continue
        }
        guard let number = names[flag] else { return 2 }
        signal(number, SIG_DFL)
    }
    let definition = MCPServerDefinition(name: "plain", command: "python3", tools: MCPToolPolicy(allow: ["*"]))
    // As serve: every serve catches them.
    let signals = MCPShutdownSignals(MCPShutdownSignals.handled, catching: true)
    defer { signals.cancel() }
    append(disposition(SIGCHLD), to: directory + "/chld")
    guard let tool = try? JSONValue.parse(#"{"name":"wait","inputSchema":{"type":"object"}}"#) else { return 1 }
    let core = MCPGatewayCore(
        configuration: MCPConfiguration(servers: [definition]), upstreams: [MCPGatewayCore.Upstream(definition: definition)],
        approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
        pinning: MCPToolPinning(pins: ["plain": ["wait": MCPToolPinStore.hash(tool)]], recordChanged: { _, _ in .recorded }),
        recordForward: { _ in true })
    let launch = MCPUpstreamLaunch(
        server: "plain", executable: "/usr/bin/env", arguments: ["python3", "-u", script, directory + "/server"],
        environment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"])
    let audit = directory + "/audit"
    let runtime = MCPGatewayRuntime(
        core: core, connections: [.process(launch)],
        audit: { record in append("\(record.tool) \(outcomeName(record.outcome))", to: audit) },
        log: { _ in })
    if let number = signals.first { return 128 + number }
    signals.forward { runtime.requestShutdown() }
    let ending = runtime.run()
    signals.cancel()
    if let number = signals.first { return 128 + number }
    return ending == .clientNotReading ? 1 : 0
}

private func writeStderrLine(_ count: Int, _ mode: String?) -> Int32 {
    signal(SIGPIPE, mode == "closed-default" ? SIG_DFL : SIG_IGN)
    switch mode {
    case "interrupted":
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(SIGALRM, &action, nil)
        var timer = itimerval(it_interval: timeval(tv_sec: 0, tv_usec: 1000), it_value: timeval(tv_sec: 0, tv_usec: 1000))
        setitimer(ITIMER_REAL, &timer, nil)
    case "closed", "closed-default":
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0, close(ends[0]) == 0, dup2(ends[1], STDERR_FILENO) == STDERR_FILENO else {
            say("no closed stderr: errno \(errno)")
            return 1
        }
        if ends[1] != STDERR_FILENO { close(ends[1]) }
    case nil: break
    default:
        say("usage: rv-mcp-probe stderr <bytes> [interrupted|closed|closed-default]")
        return 2
    }
    MCPGatewayRuntime.writeStderrLine(String(repeating: "x", count: count) + "\n")
    var off = itimerval()
    setitimer(ITIMER_REAL, &off, nil)
    say("returned")
    return 0
}

/// `connect` one datagram socket to `path`, and `sendto` one byte to it from
/// another, printing what each did.
private func unixDatagram(_ text: String) -> Int32 {
    let path = Array(text.utf8)
    var address = sockaddr_un()
    guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
        say("unix-dgram failed path too long")
        return 2
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connecting = socket(AF_UNIX, SOCK_DGRAM, 0)
    let sending = socket(AF_UNIX, SOCK_DGRAM, 0)
    guard connecting >= 0, sending >= 0 else {
        say("unix-dgram failed socket errno=\(errno)")
        return 1
    }
    defer {
        close(connecting)
        close(sending)
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(connecting, $0, size) }
    }
    let connectAnswer = connected == 0 ? "dgram-connect ok" : "dgram-connect failed errno=\(errno)"
    var byte = UInt8(ascii: "y")
    let sent = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(sending, &byte, 1, 0, $0, size) }
    }
    let sendAnswer = sent == 1 ? "dgram-sendto sent=1" : "dgram-sendto failed errno=\(errno)"
    say(connectAnswer + " " + sendAnswer)
    return 0
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first ?? "" {
case "remote-starved":
    guard arguments.count == 2, let url = URL(string: arguments[1]) else {
        say("usage: rv-mcp-probe remote-starved <url>")
        exit(2)
    }
    exit(remoteWhileStarved(url))
case "stderr":
    guard (2...3).contains(arguments.count), let count = Int(arguments[1]), count >= 0 else {
        say("usage: rv-mcp-probe stderr <bytes> [interrupted|closed|closed-default]")
        exit(2)
    }
    exit(writeStderrLine(count, arguments.count == 3 ? arguments[2] : nil))
case "pipe-disposition":
    guard arguments.count == 2 else {
        say("usage: rv-mcp-probe pipe-disposition <file>")
        exit(2)
    }
    exit(FileManager.default.createFile(atPath: arguments[1], contents: Data(pipeDisposition().utf8)) ? 0 : 1)
case "serve":
    guard arguments.count >= 3 else {
        say("usage: rv-mcp-probe serve <directory> <script> [INT] [TERM] [HUP] [CHLD-ignored]")
        exit(2)
    }
    exit(serveUnderSignals(arguments[1], arguments[2], arguments.dropFirst(3)))
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
case "hold":
    guard arguments.count == 1 else {
        say("usage: rv-mcp-probe hold")
        exit(2)
    }
    var byte: UInt8 = 0
    while true {
        let count = read(STDIN_FILENO, &byte, 1)
        if count == 0 || (count < 0 && errno != EINTR) { break }
    }
    exit(0)
case "unix-connect":
    guard arguments.count == 2 else {
        say("usage: rv-mcp-probe unix-connect <path>")
        exit(2)
    }
    let path = Array(arguments[1].utf8)
    var address = sockaddr_un()
    guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
        say("unix-connect failed path too long")
        exit(2)
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        say("unix-connect failed socket errno=\(errno)")
        exit(1)
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
        say("unix-connect failed errno=\(errno)")
        exit(1)
    }
    var byte = UInt8(ascii: "x")
    let sent = write(fd, &byte, 1)
    say(sent == 1 ? "unix-connect connected sent=1" : "unix-connect connected send failed errno=\(errno)")
    close(fd)
    exit(0)
case "unix-dgram":
    guard arguments.count == 2 else {
        say("usage: rv-mcp-probe unix-dgram <path>")
        exit(2)
    }
    exit(unixDatagram(arguments[1]))
case "peerinfo":
    // `proc_pidfdinfo` of `pid`'s fd 0 (a pipe in the tests) and
    // `proc_pid_rusage` of `pid`: whether each answered, never what.
    guard arguments.count == 2, let pid = pid_t(arguments[1]) else {
        say("usage: rv-mcp-probe peerinfo <pid>")
        exit(2)
    }
    var pipeInfo = pipe_fdinfo()
    let pipeSize = Int32(MemoryLayout<pipe_fdinfo>.size)
    let filled = proc_pidfdinfo(pid, 0, PROC_PIDFDPIPEINFO, &pipeInfo, pipeSize)
    let fdAnswer = filled == pipeSize ? "pidfdinfo ok" : "pidfdinfo failed errno=\(errno)"
    var usage = rusage_info_v0()
    let usageResult = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
    }
    let usageAnswer = usageResult == 0 ? "rusage ok" : "rusage failed errno=\(errno)"
    say(fdAnswer + " " + usageAnswer)
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
    say("usage: rv-mcp-probe signals [INT] [TERM] [HUP] | report | procargs <pid|self> [ignored...] | procargs-bytes <hex>"
        + " | hold | unix-connect <path> | unix-dgram <path> | peerinfo <pid> | remote-starved <url> | stderr <bytes> [interrupted|closed|closed-default] | pipe-disposition <file>"
        + " | serve <directory> <script> [INT] [TERM] [HUP] [CHLD-ignored]")
    exit(2)
}
