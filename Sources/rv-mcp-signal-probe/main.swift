// Test probe for `MCPShutdownSignals` (RVMCPTests). It changes real signal
// dispositions, which must not happen in the shared test process, so the
// tests run it as a child. Not shipped.
//
// `rv-mcp-signal-probe report` prints this process's dispositions.
// `rv-mcp-signal-probe` installs the shutdown signals, prints the
// dispositions it inherited and installed, spawns `report` through
// Foundation `Process` as serve spawns a plain server, sends itself SIGTERM,
// then cancels and prints the restored dispositions.
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

private func probe() -> Int32 {
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
    let deadline = Date().addingTimeInterval(5)
    while heard.value.withLock({ $0 }) == 0, Date() < deadline { usleep(10_000) }
    say("heard \(heard.value.withLock { $0 }) first \(signals.first.map { String($0) } ?? "none")")

    signals.cancel()
    say("restored " + dispositions())
    return 0
}

if CommandLine.arguments.dropFirst().first == "report" {
    say(dispositions())
    exit(0)
}
exit(probe())
