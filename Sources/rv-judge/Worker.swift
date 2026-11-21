#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVJudgePool
import RVLaya

/// `rv-judge --worker --compute accelerated|cpu --engine ft|laya --bundle DIR`
///
/// One judge worker of the pool (docs/architecture/judge-pool.md). Spawned
/// only by `rv-judge serve`: stdin carries length-prefixed `WorkerRequest`
/// frames, stdout carries `WorkerEvent` frames, nothing else is written to
/// stdout. Loads the model once, answers one request at a time, and exits
/// when stdin closes (the supervisor is gone). A worker that hangs or
/// aborts costs only itself: the supervisor kills and respawns it.
///
/// Every load goes through the worker's own `CoreMLGuard`
/// (`guard-<compute>` under the account's `~/.config/rv/cache/laya`): its
/// crash history drives only its own compute units, and its compiled model
/// comes from the shared verified store. A refusal (disk nearly full, a
/// model it could not verify) is reported as a load failure, which rvd
/// answers with review.
enum JudgeWorker {
    /// `<passwd home>/.config/rv/cache/laya`: never from `$HOME` or argv.
    static func stateRoot() -> URL? {
        JudgePoolServe.passwdHome().map {
            CoreMLGuard.stateRoot(configDirectory: URL(fileURLWithPath: $0, isDirectory: true)
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("rv", isDirectory: true))
        }
    }

    /// The supervisor's `reapedAfterKill`: a worker it SIGKILLed after the
    /// worker's guard started did not crash inside Core ML, so its in-flight
    /// marker is cleared before the replacement reads it.
    static func clearMarker(after compute: WorkerCompute) {
        guard let root = stateRoot() else { return }
        FileCoreMLCrashStore.clearStaleMarker(
            directory: CoreMLGuard.workerMarkerDirectory(stateRoot: root, worker: compute.rawValue))
    }

    static func main(_ arguments: [String]) -> Never {
        // A dead supervisor turns writes into EPIPE, and the loop exits.
        signal(SIGPIPE, SIG_IGN)
        guard let options = WorkerOptions.parse(arguments) else {
            FileHandle.standardError.write(Data("rv-judge --worker: bad arguments\n".utf8))
            exit(2)
        }
        #if canImport(CoreML)
        run(options)
        #else
        emit(.loadFailed(LoadFailure(kind: .modelUnavailable, message: "CoreML unavailable on this platform")))
        exit(0)
        #endif
    }

    #if canImport(CoreML)
    private static func run(_ options: WorkerOptions) -> Never {
        let coreML = CoreMLGuard.worker(
            stateRoot: stateRoot(), worker: options.compute.rawValue, cpuOnly: options.compute == .cpu,
            log: JudgePoolLog.line)
        // Crash recovery first (it reads the previous generation's marker),
        // then tell the supervisor: from here a marker is this worker's own,
        // so the supervisor's SIGKILL may clear it.
        _ = coreML.computeUnits
        emit(.guardStarted)
        let bundle = URL(fileURLWithPath: options.bundle, isDirectory: true)
        let judge: (JudgeInput) throws -> LayaVerdict
        let checkpoint: String
        do {
            if options.engine == "ft" {
                let model = try FineTunedJudge(bundleDir: bundle, coreML: coreML)
                checkpoint = model.checkpoint
                judge = { try model.judge($0.command, contextLines: $0.contextLines) }
            } else {
                let model = try LayaCoreMLJudge(bundleDir: bundle, coreML: coreML)
                checkpoint = model.checkpoint
                judge = { try model.judge($0.command) }
            }
        } catch let refusal as any CoreMLRefusal {
            emit(.loadFailed(LoadFailure(kind: .modelUnavailable, message: refusal.reason)))
            exit(0)
        } catch let error as LayaError {
            emit(.loadFailed(loadFailure(error)))
            exit(0)
        } catch {
            emit(.loadFailed(LoadFailure(kind: .modelUnavailable, message: "load failed")))
            exit(0)
        }
        // The first prediction after a load runs 0.3-0.5 s longer than the
        // rest (measured); pay it here so no real request waits on it.
        _ = try? judge(JudgeInput(command: "true", contextLines: []))
        emit(.ready(checkpoint: checkpoint))
        while let body = readFrame() {
            guard let request = JudgePoolJSON.decode(WorkerRequest.self, from: body) else { exit(3) }
            if let verdict = try? judge(request.input), let data = JudgePoolJSON.encode(verdict) {
                emit(.verdict(id: request.id, verdict: data))
            } else {
                emit(.failed(id: request.id))
            }
        }
        exit(0)
    }

    private static func loadFailure(_ error: LayaError) -> LoadFailure {
        switch error {
        case .badBundle(let why): LoadFailure(kind: .badBundle, message: why)
        case .modelUnavailable(let why): LoadFailure(kind: .modelUnavailable, message: why)
        case .predictionFailed(let why): LoadFailure(kind: .modelUnavailable, message: why)
        }
    }
    #endif

    private static func emit(_ event: WorkerEvent) {
        guard let frame = FrameStream.frame(json: event) else { exit(4) }
        guard writeAll(frame, to: STDOUT_FILENO) else { exit(0) }
    }

    /// One frame body from stdin; nil at EOF. A framing error exits.
    private static func readFrame() -> Data? {
        guard let header = readExactly(4, from: STDIN_FILENO) else { return nil }
        var decoder = FrameStreamDecoder()
        _ = decoder.feed(header)
        let declared = header.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).bigEndian) }
        guard decoder.failed == nil, let body = readExactly(declared, from: STDIN_FILENO),
              let frame = decoder.feed(body).first else { exit(3) }
        return frame
    }

    private static func readExactly(_ count: Int, from fd: Int32) -> Data? {
        var data = Data(count: count)
        var filled = 0
        while filled < count {
            let n = data.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress.map { $0 + filled }, count - filled)
            }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return nil }
            filled += n
        }
        return data
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, base, remaining)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                remaining -= n
                base += n
            }
            return true
        }
    }
}
