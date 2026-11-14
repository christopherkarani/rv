// `rv run`'s signal handling with real dispositions and real signals, for
// RVIsolationTests. It runs here, in a process of its own, because the
// guard changes process-wide dispositions: in the test process every child
// another suite spawned meanwhile would inherit the signals rv ignores.
//
//   rv-run-probe guards                     the shared installation
//   rv-run-probe run DIRECTORY COMMAND...   `rv run --secret OPENAI_API_KEY`
//
// Each failed check is one `rv-run-probe: FAIL` line on stderr.
#if os(macOS)
import Darwin
import Foundation
import RVIsolation

enum RunProbe {
    /// Everything the guard changes, and SIGPIPE, which it must leave alone.
    static let watched = [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGTTOU, SIGCHLD, SIGPIPE]

    /// As under `nohup` and a parent that ignores SIGPIPE: rv inherits both
    /// ignored, and the command must keep them ignored. A SIGCHLD handler
    /// of rv's own, which the guard must set aside while it is open.
    static func prepare() {
        _ = signal(SIGHUP, SIG_IGN)
        _ = signal(SIGPIPE, SIG_IGN)
        let noted: sig_t = { _ in }
        _ = signal(SIGCHLD, noted)
    }

    /// Two guards share one installation, which the last one out restores
    /// whichever order they leave in. A real SIGINT reaches every guard,
    /// SIGCHLD is default meanwhile, and what rv inherited ignored is
    /// reported apart from what rv ignores itself.
    static func guards() -> [String] {
        var failures: [String] = []
        prepare()
        let before = watched.map(disposition)
        for lastOut in [0, 1] {
            let guards = [SecretRunSignals(), SecretRunSignals()]
            let pass = "guards leaving last \(lastOut):"
            if SecretRunSignals.installed == false { failures.append("\(pass) nothing installed") }
            if disposition(SIGINT) != ignored { failures.append("\(pass) SIGINT not ignored") }
            if disposition(SIGCHLD) != 0 { failures.append("\(pass) SIGCHLD not default") }
            let inherited = guards[0].inheritedIgnored
            if inherited.isSuperset(of: [SIGHUP, SIGPIPE]) == false
                || inherited.isDisjoint(with: [SIGINT, SIGQUIT, SIGTERM, SIGTTOU]) == false
            {
                failures.append("\(pass) inherited ignored \(inherited.sorted()), expected SIGHUP and SIGPIPE only")
            }
            let delivered = SecretRunSignals.deliveredCount
            _ = kill(getpid(), SIGINT)
            let deadline = Date().addingTimeInterval(10)
            while SecretRunSignals.deliveredCount == delivered, Date() < deadline { usleep(1_000) }
            if guards.allSatisfy({ $0.interrupted == SIGINT }) == false {
                failures.append("\(pass) a SIGINT did not reach every guard")
            }
            guards[1 - lastOut].restore()
            guards[1 - lastOut].restore()  // idempotent: it does not leave on the other's behalf
            if SecretRunSignals.installed == false || disposition(SIGTERM) != ignored {
                failures.append("\(pass) the first guard out restored for both")
            }
            guards[lastOut].restore()
            if SecretRunSignals.installed { failures.append("\(pass) still installed after the last guard left") }
            let after = watched.map(disposition)
            if after != before { failures.append("\(pass) dispositions \(after) after, \(before) before") }
        }
        return failures
    }

    /// The production path, as `rv run --secret OPENAI_API_KEY -- COMMAND`
    /// in DIRECTORY. The command writes `$OPENAI_BASE_URL` to
    /// `DIRECTORY/url`; once the run is over the gateway behind it must be
    /// gone, and rv's dispositions back as they were.
    static func run(directory: String, command: [String]) -> (code: Int32, failures: [String]) {
        prepare()
        let before = watched.map(disposition)
        let request = SecretRunRequest(secrets: ["OPENAI_API_KEY"], all: false, command: command)
        let outcome = SecretRunContext.production(
            environment: ProcessInfo.processInfo.environment, directory: directory,
            notice: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        ).flatMap { SecretRun.execute(request, context: $0) }
        var failures: [String] = []
        let after = watched.map(disposition)
        if after != before { failures.append("run: dispositions \(after) after, \(before) before") }
        let url = (try? String(contentsOfFile: directory + "/url", encoding: .utf8))
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let port = url?.port {
            if loopbackAccepts(port: port) { failures.append("run: the gateway still listens on \(port)") }
        } else {
            failures.append("run: the command wrote no gateway base URL")
        }
        switch outcome {
        case .success(let code):
            return (code, failures)
        case .failure(let refusal):
            FileHandle.standardError.write(Data("rv run: \(refusal.message)\n".utf8))
            return (refusal.exitCode, failures)
        }
    }

    static let ignored = unsafeBitCast(SIG_IGN as sig_t?, to: Int.self)

    /// The handler for `number`, as a number: 0 is SIG_DFL.
    static func disposition(_ number: Int32) -> Int {
        var action = sigaction()
        _ = sigaction(number, nil, &action)
        return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
    }

    static func loopbackAccepts(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    static func main(_ arguments: [String]) -> Int32 {
        let code: Int32
        let failures: [String]
        switch arguments.first {
        case "guards" where arguments.count == 1:
            failures = guards()
            code = failures.isEmpty ? 0 : 1
        case "run" where arguments.count >= 3:
            let outcome = run(directory: arguments[1], command: Array(arguments.dropFirst(2)))
            code = outcome.code
            failures = outcome.failures
        default:
            FileHandle.standardError.write(Data("usage: rv-run-probe guards | run DIRECTORY COMMAND...\n".utf8))
            return 2
        }
        for failure in failures { FileHandle.standardError.write(Data("rv-run-probe: FAIL \(failure)\n".utf8)) }
        return code
    }
}

exit(RunProbe.main(Array(CommandLine.arguments.dropFirst())))
#else
import Foundation
exit(2)
#endif
