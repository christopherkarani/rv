import Foundation
import Testing
import RVDomain
@testable import RVEngine

/// Inputs that crashed or stalled the rvd stop guard. rvd serves requests
/// on the cooperative pool (512 KB stacks on Darwin); a crash or a
/// verdict past the hook's 8 s budget leaves rvd unreachable, and an
/// observe hook then allows every later call unchecked.
@Suite("rvd stop guard bounds")
struct RVDStopGuardBoundsTests {
    /// Loose so a starved CI pool does not flake; in a debug build the
    /// regressions ran 49 s to 292 s, the fixed code under 4 s.
    private static let wallClockBound = Duration.seconds(20)

    /// `xargs xargs … ` nested about 600 deep recursed once per `xargs` and
    /// overflowed a 512 KB stack. Past the launcher cap it fails closed.
    @Test("stop guard: a deep xargs chain fails closed on a 512 KB stack")
    func deepXargsChainFailsClosed() {
        let raw = String(repeating: "xargs ", count: 600) + "true"
        let stops = onSmallStack { RVDStopGuard.stopsRVD(raw) }
        #expect(stops == true)
    }

    @Test("stop guard: a short xargs chain is still read through", arguments: [
        ("xargs xargs pkill rvd", true),
        ("xargs -n1 xargs -I{} kill -1", true),
        ("xargs xargs echo hi", false),
        ("find . -name '*.o' | xargs rm", false),
    ])
    func shortXargsChainReads(raw: String, stops: Bool) {
        #expect(RVDStopGuard.stopsRVD(raw) == stops, "\(raw)")
    }

    /// Thousands of `kill` operands read the process table once, not once
    /// per operand.
    @Test("stop guard: a long literal-pid kill reads the process table once")
    func killReadsProcessTableOnce() {
        let raw = "kill " + Array(repeating: "1", count: 32768).joined(separator: " ")
        let reads = Counter()
        let clock = ContinuousClock()
        var stops = true
        let elapsed = clock.measure {
            stops = RVDStopGuard.stopsRVD(raw, rvdPIDs: { reads.bump(); return [] })
        }
        #expect(stops == false)
        #expect(reads.value == 1)
        #expect(elapsed < Self.wallClockBound, "\(elapsed)")
    }

    @Test("stop guard: a literal pid that is rvd's still holds")
    func killOfRVDPidHolds() {
        #expect(RVDStopGuard.stopsRVD("kill 1 2 3 4242", rvdPIDs: { [4242] }))
        #expect(RVDStopGuard.stopsRVD("kill 7; kill 4242", rvdPIDs: { [4242] }))
        #expect(RVDStopGuard.stopsRVD("kill 7", rvdPIDs: { nil }))
        #expect(RVDStopGuard.stopsRVD("kill 7 8", rvdPIDs: { [4242] }) == false)
    }

    /// `pkill pkill pkill …` made one speculative tail per word, each
    /// re-judged to the end of the line: quadratic. Past the tail budget
    /// the guard fails closed.
    @Test("stop guard: thousands of lifecycle words fail closed fast")
    func manyLifecycleWordsFailClosedFast() {
        for word in ["pkill", "kill", "killall", "launchctl", "systemctl"] {
            let raw = String(repeating: "\(word) ", count: 2000)
            let clock = ContinuousClock()
            var stops = false
            let elapsed = clock.measure { stops = RVDStopGuard.stopsRVD(raw, rvdPIDs: { [] }) }
            #expect(stops, "\(word)")
            #expect(elapsed < Self.wallClockBound, "\(word): \(elapsed)")
        }
    }

    /// The evaluator's own xargs peel re-entered unwrap at depth 0 for each
    /// nested `xargs` and overflowed the stack before any floor ran.
    @Test("unwrap: a deep xargs chain is limited on a 512 KB stack")
    func deepXargsUnwrapIsLimited() {
        let deep = String(repeating: "xargs ", count: 600) + "true"
        let limited = onSmallStack {
            if case .limited = ShellPipeline.unwrap(deep, workingDirectory: nil, budget: .default, depth: 0, layers: []) {
                return true
            }
            return false
        }
        #expect(limited)
        let short = ShellPipeline.unwrap("xargs xargs ls", workingDirectory: nil, budget: .default, depth: 0, layers: [])
        guard case .complete(let unwrapped) = short else {
            Issue.record("two nested xargs must still unwrap: \(short)")
            return
        }
        #expect(unwrapped.command.rawValue == "ls")
    }

    /// The literal fast path answers exactly as the regex would.
    @Test("regex bound: a literal pattern matches as the regex does", arguments: [
        "rvd", "RVD", "rv", "vd", "r", "d", "x", "rvdx", "bin/rvd", "--socket", "local", "dev", "dev-rv",
        "evaluate", "rv evaluate", " ", "-", "=", "'v1'", "k1", "/Users/u/.local/bin/rvd --socket",
    ])
    func literalPatternsMatchLikeRegex(pattern: String) throws {
        let subjects = ["rvd", "dev.rv.evaluate", "/Users/u/.local/bin/rvd --socket"]
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let expected = subjects.contains { subject in
            regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
        }
        #expect(boundedRegexMatches(pattern, subjects: subjects) == expected, "\(pattern)")
    }

    @Test("stop guard: a few lifecycle words in one line are still judged", arguments: [
        ("echo a; kill %1; pkill -f 'rails s'", false),
        ("pkill -f 'rails s' && pkill -f sidekiq", false),
        ("find . -exec pkill rvd \\;", true),
        ("sudo -u x killall rvd", true),
    ])
    func fewLifecycleWordsJudged(raw: String, stops: Bool) {
        #expect(RVDStopGuard.stopsRVD(raw, rvdPIDs: { [] }) == stops, "\(raw)")
    }
}

/// Runs `body` on a thread with rvd's cooperative-pool stack size.
private func onSmallStack<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.set(body())
        done.signal()
    }
    thread.stackSize = 512 * 1024
    thread.start()
    done.wait()
    return box.get()!
}

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ new: T) { lock.withLock { value = new } }
    func get() -> T? { lock.withLock { value } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
