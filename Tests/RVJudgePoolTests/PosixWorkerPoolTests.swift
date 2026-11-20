#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVJudgePool

/// The real supervisor driving real child processes over pipes: fake
/// workers in Python (no Core ML), so a `kill -9` and a hang are the real
/// thing. Skipped where no python3 exists.
@Suite("Judge pool with real worker processes", .serialized)
struct PosixWorkerPoolTests {
    static let python: String? = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Answers each request with a verdict naming its mode, after logging
    /// `pid id` to the marker file. `hang` never answers.
    static let script = #"""
    import base64, json, os, struct, sys, time
    mode, marker = sys.argv[1], sys.argv[2]
    out, inp = sys.stdout.buffer, sys.stdin.buffer
    def send(o):
        b = json.dumps(o).encode()
        out.write(struct.pack(">I", len(b)) + b)
        out.flush()
    send({"ready": {"checkpoint": "fake-" + mode}})
    while True:
        h = inp.read(4)
        if len(h) < 4:
            sys.exit(0)
        r = json.loads(inp.read(struct.unpack(">I", h)[0]))
        with open(marker, "a") as f:
            f.write("%d %s\n" % (os.getpid(), r["id"]))
        if mode == "hang":
            time.sleep(3600)
        v = base64.b64encode(json.dumps({"from": mode}).encode()).decode()
        send({"verdict": {"id": r["id"], "verdict": v}})
    """#

    let key = ModelKey(engine: "ft", bundle: "/models/fake")
    let input = JudgeInput(command: "echo hi", contextLines: [])

    struct Fixture {
        let directory: URL
        let supervisor: JudgePoolSupervisor

        func marker(_ slot: WorkerSlot) -> URL { directory.appendingPathComponent("\(slot.rawValue).log") }

        /// Pids that received a request, in order.
        func pids(_ slot: WorkerSlot) -> [pid_t] {
            guard let text = try? String(contentsOf: marker(slot), encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { $0.split(separator: " ").first.flatMap { pid_t($0) } }
        }
    }

    func fixture(python: String, policy: PoolPolicy, modes: [WorkerSlot: String]) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-judge-pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("worker.py")
        try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let spawner = PosixWorkerSpawner(executable: python, environment: ["PATH": "/usr/bin:/bin"]) { slot, _, _ in
            ["-I", "-S", scriptURL.path, modes[slot] ?? "ok", directory.appendingPathComponent("\(slot.rawValue).log").path]
        }
        return Fixture(directory: directory, supervisor: JudgePoolSupervisor(policy: policy, spawner: spawner))
    }

    /// Polls `condition` every 20 ms for up to `seconds`.
    func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func bothReady(_ supervisor: JudgePoolSupervisor) -> Bool {
        supervisor.status().workers.allSatisfy { $0.phase == "ready" }
    }

    func from(_ outcome: PoolOutcome) -> (String?, WorkerSlot?) {
        guard case .verdict(let data, let slot) = outcome,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return (nil, nil) }
        return (object["from"], slot)
    }

    @Test("kill -9 of the busy worker: the request is still answered, by the other worker", .enabled(if: python != nil, "python3 not installed"))
    func killNineMidRequest() async throws {
        let python = try #require(Self.python)
        // Hedging and the budget kill are pushed out of the way: only the
        // crash can move this request to the hedge.
        let policy = PoolPolicy(hedgeAfter: .seconds(20), budget: .seconds(30), backoffBase: .milliseconds(50))
        let pool = try fixture(python: python, policy: policy, modes: [.primary: "hang", .hedge: "ok"])
        defer {
            pool.supervisor.stop()
            try? FileManager.default.removeItem(at: pool.directory)
        }
        pool.supervisor.warm(key: key)
        #expect(await eventually { bothReady(pool.supervisor) })

        async let answer = pool.supervisor.submit(key: key, input: input, budget: .seconds(30))
        #expect(await eventually { !pool.pids(.primary).isEmpty })
        let victim = try #require(pool.pids(.primary).first)
        #expect(kill(victim, SIGKILL) == 0)

        let (source, slot) = from(await answer)
        #expect(source == "ok")
        #expect(slot == .hedge)
        // A is respawned (backoff 50 ms) and loads again.
        #expect(await eventually { pool.supervisor.status().workers.first { $0.slot == .primary }?.restarts ?? 0 >= 1 })
    }

    @Test("a hung primary: hedged, then SIGKILLed at the budget and respawned", .enabled(if: python != nil, "python3 not installed"))
    func hangHedgesThenKills() async throws {
        let python = try #require(Self.python)
        let policy = PoolPolicy(hedgeAfter: .milliseconds(150), budget: .milliseconds(600), backoffBase: .milliseconds(50))
        let pool = try fixture(python: python, policy: policy, modes: [.primary: "hang", .hedge: "ok"])
        defer {
            pool.supervisor.stop()
            try? FileManager.default.removeItem(at: pool.directory)
        }
        pool.supervisor.warm(key: key)
        #expect(await eventually { bothReady(pool.supervisor) })

        let (source, slot) = from(await pool.supervisor.submit(key: key, input: input, budget: .seconds(5)))
        #expect(source == "ok")
        #expect(slot == .hedge)
        // Ordering, not wall clock: a request still unanswered at the budget
        // kill answers late, so a hedge verdict and a hedge win mean the hedge
        // answered before the kill.
        #expect(pool.supervisor.status().hedgeWins == 1)
        let hung = try #require(pool.pids(.primary).first)

        // The hung process is killed at the budget, never left running.
        #expect(await eventually { kill(hung, 0) != 0 && errno == ESRCH })
        let status = pool.supervisor.status()
        #expect(status.killed == 1)
        #expect(await eventually { pool.supervisor.status().workers.first { $0.slot == .primary }?.restarts ?? 0 >= 1 })
    }

    @Test("a worker that is not an executable is a spawn failure, retried with backoff, never an answer")
    func spawnFailure() async throws {
        let spawner = PosixWorkerSpawner(executable: "/nonexistent/rv-judge", environment: [:]) { _, _, _ in [] }
        let policy = PoolPolicy(budget: .milliseconds(300), backoffBase: .milliseconds(50))
        let supervisor = JudgePoolSupervisor(policy: policy, spawner: spawner)
        defer { supervisor.stop() }
        let outcome = await supervisor.submit(key: key, input: input, budget: .milliseconds(300))
        if case .verdict = outcome { Issue.record("a pool with no workers must not produce a verdict") }
    }
}
