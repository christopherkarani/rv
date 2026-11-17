// Test probe for RVMCPTests' signal tests, run as a child, on macOS and
// Linux. Not shipped.
//
// `rv-mcp-signal-probe signals [INT] [TERM] [HUP]` sets the named signals to
// the default, then installs `MCPShutdownSignals`, which changes real
// signal dispositions (never done in the shared test process). It prints the
// dispositions it inherited and installed, spawns `report` through
// Foundation `Process`, sends itself SIGTERM, then cancels and prints the
// restored dispositions.
// `rv-mcp-signal-probe report` prints this process's dispositions.
// `rv-mcp-signal-probe serve <directory> <script> [INT] [TERM] [HUP] [CHLD-ignored] [plan-hangs]`
// sets the named signals to the default (and SIGCHLD to ignored), then
// serves one plain stdio server, `python3 -u <script> <directory>/server`,
// through serve's own signal wiring (`MCPShutdownSignals.plan` and
// `serve`), with this probe's stdin and stdout as the client. It writes
// SIGCHLD's disposition once the signals are set up to `<directory>/chld`,
// one `<tool> <outcome>` line per audit record to `<directory>/audit`, and
// exits as serve would. `plan-hangs` makes its planning never return
// (it writes `<directory>/planning` first), as a hung secret provider would.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVMCP
import Synchronization

private final class Count: Sendable {
    let value = Mutex(0)
}

private func handlerBits(_ action: sigaction) -> Int {
    #if canImport(Darwin)
    unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
    #else
    unsafeBitCast(action.__sigaction_handler.sa_handler, to: Int.self)
    #endif
}

private func setDefault(_ number: Int32) -> Bool {
    var action = sigaction()
    #if canImport(Darwin)
    action.__sigaction_u.__sa_handler = SIG_DFL
    #else
    action.__sigaction_handler.sa_handler = SIG_DFL
    #endif
    sigemptyset(&action.sa_mask)
    return sigaction(number, &action, nil) == 0
}

/// What signal `number` is set to now: `default`, `ignore` or `handler`.
private func disposition(_ number: Int32) -> String {
    var current = sigaction()
    guard sigaction(number, nil, &current) == 0 else { return "unreadable" }
    let handler = handlerBits(current)
    let ignore = unsafeBitCast(SIG_IGN as sig_t?, to: Int.self)
    return handler == 0 ? "default" : handler == ignore ? "ignore" : "handler"
}

private func dispositions() -> String {
    [(SIGINT, "INT"), (SIGTERM, "TERM"), (SIGHUP, "HUP")].map { "\($0.1)=\(disposition($0.0))" }.joined(separator: " ")
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
    var planHangs = false
    for flag in flags {
        if flag == "CHLD-ignored" {
            signal(SIGCHLD, SIG_IGN)
            continue
        }
        if flag == "plan-hangs" {
            planHangs = true
            continue
        }
        guard let number = names[flag], setDefault(number) else { return 2 }
    }
    let definition = MCPServerDefinition(name: "plain", command: "python3", tools: MCPToolPolicy(allow: ["*"]))
    // As serve: every serve catches them, and refuses to run without.
    let signals = MCPShutdownSignals(MCPShutdownSignals.handled, catching: true)
    defer { signals.cancel() }
    guard signals.installed else { return 3 }
    append(disposition(SIGCHLD), to: directory + "/chld")
    let launch = MCPUpstreamLaunch(
        server: "plain", executable: "/usr/bin/env", arguments: ["python3", "-u", script, directory + "/server"],
        environment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"])
    let planned: MCPUpstreamLaunch? = signals.plan {
        if planHangs {
            append("planning", to: directory + "/planning")
            while true { _ = sleep(60) }
        }
        return launch
    }
    guard let planned, signals.first == nil else { return 128 + (signals.first ?? SIGTERM) }
    guard let tool = try? JSONValue.parse(#"{"name":"wait","inputSchema":{"type":"object"}}"#) else { return 1 }
    let core = MCPGatewayCore(
        configuration: MCPConfiguration(servers: [definition]), upstreams: [MCPGatewayCore.Upstream(definition: definition)],
        approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
        pinning: MCPToolPinning(pins: ["plain": ["wait": MCPToolPinStore.hash(tool)]], recordChanged: { _, _ in .recorded }),
        recordForward: { _ in true })
    let audit = directory + "/audit"
    let runtime = MCPGatewayRuntime(
        core: core, connections: [.process(planned)],
        audit: { record in append("\(record.tool) \(outcomeName(record.outcome))", to: audit) },
        log: { _ in })
    if let number = signals.first { return 128 + number }
    return signals.serve(runtime) ?? 0
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first ?? "" {
case "serve":
    guard arguments.count >= 3 else {
        say("usage: rv-mcp-signal-probe serve <directory> <script> [INT] [TERM] [HUP] [CHLD-ignored] [plan-hangs]")
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
        guard let number = names[name], setDefault(number) else {
            say("usage: rv-mcp-signal-probe signals [INT] [TERM] [HUP]")
            exit(2)
        }
    }
    exit(catchSignals())
default:
    say("usage: rv-mcp-signal-probe signals [INT] [TERM] [HUP] | report"
        + " | serve <directory> <script> [INT] [TERM] [HUP] [CHLD-ignored] [plan-hangs]")
    exit(2)
}
