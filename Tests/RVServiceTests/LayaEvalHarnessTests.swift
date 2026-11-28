import Foundation
import Testing
import RVDomain
import RVHistory
import RVLaya
import RVPolicy
@testable import RVService

/// Laya judge precision/recall harness over `Scripts/laya/eval/corpus.json`
/// (see `Scripts/laya/eval/README.md`).
///
/// Opt-in only: the suite is disabled unless `RV_LAYA_EVAL=1`, needs a judge
/// bundle installed under the real home (`~/.config/rv/models/...`), runs
/// on a Mac only, and never runs in CI. Run it with
/// `RV_LAYA_EVAL=1 swift test --filter LayaEvalHarness`, or through
/// `Scripts/laya/eval/drive.sh`, which resumes after a Core ML crash.
///
/// Runs every corpus command through the production gated door
/// (packs -> package-script screen -> safe lane -> JudgeRuntime.apply), in
/// enforce mode, twice: judge ON (real installed bundle via the production
/// `JudgeRuntime.runJudge`) and judge OFF (`.unavailable`, i.e. the
/// packs-only floor production uses when no bundle is installed). It also
/// records the model-only verdict for every command (judge called even when
/// packs deny or the safe lane would skip it), at production thresholds,
/// plus two diagnostics per command: the bare command and the full
/// training-format context.
///
/// Each command runs in two workspaces: `in-repo` (a dirty git tree) and
/// `no-repo` (the same files, no repository). The context lines each gets
/// are whatever production `JudgeRuntime.judgeContext` sends there, recorded
/// per row as `contextLines`.
///
/// Env: `RV_LAYA_EVAL_OUT_DIR` (default `Scripts/laya/eval/out/`, ignored by
/// git) receives `results.jsonl` and `meta.json`; `RV_LAYA_EVAL_START` resumes
/// at a corpus index (appending); `RV_LAYA_EVAL_LIMIT` caps the row count.
/// Score the run with `python3 -I Scripts/laya/eval/metrics.py`.
///
/// When the `judge.mode` setting lands (an unset mode means shadow: the
/// judge never decides), build `selection` below as live (shadow off), or
/// the door-ON numbers measure packs only, not the judge deciding.
@Suite("Laya eval harness", .enabled(if: ProcessInfo.processInfo.environment["RV_LAYA_EVAL"] == "1"))
struct LayaEvalHarnessTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let evalDir = root.appendingPathComponent("Scripts/laya/eval", isDirectory: true)
    static let outDir: URL = {
        if let dir = ProcessInfo.processInfo.environment["RV_LAYA_EVAL_OUT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return LayaEvalHarnessTests.evalDir.appendingPathComponent("out", isDirectory: true)
    }()

    struct Row: Decodable {
        let id: String
        let set: String
        let category: String
        let command: String
        let heldout: Bool
    }

    @Test func run() async throws {
        let fm = FileManager.default
        let rows = try JSONDecoder().decode(
            [Row].self, from: Data(contentsOf: Self.evalDir.appendingPathComponent("corpus.json")))
        let limit = Int(ProcessInfo.processInfo.environment["RV_LAYA_EVAL_LIMIT"] ?? "") ?? rows.count
        try fm.createDirectory(at: Self.outDir, withIntermediateDirectories: true)

        // Production engine resolution against the owner's real home
        // (read-only). The bundle is reached through a symlink so the
        // compiled-model cache key differs from the live rvd's entry.
        // The home comes from RV_LAYA_EVAL_HOME, else $HOME (the repo's
        // preflight bans the Foundation home lookup in Tests).
        let env = ProcessInfo.processInfo.environment
        let homePath = try #require(env["RV_LAYA_EVAL_HOME"] ?? env["HOME"], "set HOME or RV_LAYA_EVAL_HOME")
        let realHome = try #require(HomeDirectory(validating: homePath))
        let config = GuardConfig.read(home: realHome)
        guard let resolved = JudgeRuntime.resolvedJudge(home: realHome, config: config) else {
            try writeMeta(["error": "no judge bundle resolved for the real home"])
            Issue.record("no judge bundle installed; refusing to run a stub")
            return
        }
        let work = fm.temporaryDirectory.appendingPathComponent("rv-laya-eval-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let bundleLink = work.appendingPathComponent(resolved.bundle.lastPathComponent)
        try fm.createSymbolicLink(at: bundleLink, withDestinationURL: resolved.bundle)
        defer { removeCompiledCache(for: bundleLink) }

        // Temp home (door effects land here, never in the real config dir)
        // with an in-repo workspace (dirty git tree) and a no-repo twin.
        let homeURL = work.appendingPathComponent("home", isDirectory: true)
        let inRepo = homeURL.appendingPathComponent("CodingProjects/app", isDirectory: true)
        let noRepo = homeURL.appendingPathComponent("scratch/app", isDirectory: true)
        for dir in [inRepo, noRepo] { try seedWorkspace(dir) }
        try git(["init", "-q", "-b", "main"], in: inRepo)
        try git(["add", "-A"], in: inRepo)
        try git(["-c", "user.name=eval", "-c", "user.email=eval@example.invalid", "commit", "-qm", "init"], in: inRepo)
        try "// edited\n".write(to: inRepo.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
        try "notes\n".write(to: inRepo.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)
        let home = try #require(HomeDirectory(validating: homeURL.path))

        let recorder = RecordingJudge()
        let session = EvaluateSession()
        let doorOn = GatedEvaluate(session, judge: recorder)
        let doorOff = GatedEvaluate(session, judge: EffectFixedJudge(run: .unavailable("eval-judge-off")))
        // Live judge. Once `judge.mode` lands this must select shadow off
        // explicitly (see the type comment).
        let selection = JudgeSelection(engine: resolved.engine, bundle: bundleLink)

        // Load + confirm the real model (no stub): first call blocks on load.
        let loadStart = ContinuousClock.now
        let warm = JudgeRuntime.runJudge(
            command: "ls", context: JudgeContext(), engine: resolved.engine, bundle: bundleLink, wait: nil)
        let loadMs = ms(ContinuousClock.now - loadStart)
        guard case .verdict(let warmVerdict) = warm else {
            try writeMeta(["error": "model did not load: \(warm)", "engine": resolved.engine.rawValue])
            Issue.record("real model did not load: \(warm)")
            return
        }

        let contexts: [(String, URL)] = [("in-repo", inRepo), ("no-repo", noRepo)]
        let start = Int(ProcessInfo.processInfo.environment["RV_LAYA_EVAL_START"] ?? "") ?? 0
        let out = Self.outDir.appendingPathComponent("results.jsonl")
        if start == 0 || !fm.fileExists(atPath: out.path) { fm.createFile(atPath: out.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: out)
        _ = try handle.seekToEnd()
        defer { try? handle.close() }

        let fullContext = JudgeContext(cwdInsideRepo: true, gitUntracked: 1, gitModified: 2, gitStaged: 0)
        for (index, row) in rows.prefix(limit).enumerated() where index >= start {
            print("laya-eval-at \(index) \(row.id)")
            let command = ShellCommand(rawValue: row.command)
            // Diagnostics (context-independent of the workspace): bare
            // command, and the full training-format context.
            let bare = timedRun(row.command, JudgeContext(), resolved.engine, bundleLink)
            let full = timedRun(row.command, fullContext, resolved.engine, bundleLink)
            for (name, dir) in contexts {
                let cwd = try #require(WorkingDirectory(validating: dir.path))
                let ctx = JudgeRuntime.judgeContext(cwd: cwd)
                let model = timedRun(row.command, ctx, resolved.engine, bundleLink)
                recorder.prime(command: row.command, lines: ctx.lines(), run: model.run)
                let request = GatedEvaluate.makeRequest(command: command, home: home)
                let inputs = EvaluationInputs(
                    guardMode: .enforce, judge: selection, store: .gather(home: home, cwd: cwd))
                let t0 = ContinuousClock.now
                let on = await doorOn.gated(
                    .peek, request, cwd: cwd, home: home, grants: EphemeralAllowOnceTable(),
                    now: Date(), allowlist: { .empty }, host: .hook(.claude), tool: .bash, inputs: inputs)
                let doorMs = ms(ContinuousClock.now - t0)
                let called = recorder.takeCalled()
                let off = await doorOff.gated(
                    .peek, request, cwd: cwd, home: home, grants: EphemeralAllowOnceTable(),
                    now: Date(), allowlist: { .empty }, host: .hook(.claude), tool: .bash, inputs: inputs)
                let record: [String: Any] = [
                    "id": row.id, "set": row.set, "category": row.category, "heldout": row.heldout,
                    "command": row.command, "context": name, "contextLines": ctx.lines(),
                    "safeLane": SafeCommandLane.isSafe(row.command),
                    "doorOn": describe(on.decision), "doorOff": describe(off.decision),
                    "judgeCalled": called, "doorMs": doorMs,
                    "model": describe(model), "bare": describe(bare), "full": describe(full),
                ]
                var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                line.append(0x0A)
                try handle.write(contentsOf: line)
            }
            if index % 50 == 0 { print("laya-eval \(index)/\(min(limit, rows.count))") }
        }
        try writeMeta([
            "engine": resolved.engine.rawValue,
            "bundle": resolved.bundle.lastPathComponent,
            "checkpoint": warmVerdict.checkpoint,
            "loadMs": loadMs,
            "rows": min(limit, rows.count),
            "thresholds": ["block": 0.8, "review": 0.45],
            "provenance": "unknown",
        ])
    }

    // MARK: helpers

    struct Timed { let run: JudgeRuntime.JudgeRun; let wallMs: Double }

    func timedRun(_ command: String, _ ctx: JudgeContext, _ engine: JudgeEngine, _ bundle: URL) -> Timed {
        let t0 = ContinuousClock.now
        let run = JudgeRuntime.runJudge(command: command, context: ctx, engine: engine, bundle: bundle, wait: nil)
        return Timed(run: run, wallMs: ms(ContinuousClock.now - t0))
    }

    func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    func describe(_ decision: Decision) -> [String: Any] {
        switch decision {
        case .allow: return ["decision": "allow"]
        case .deny(let deny): return ["decision": "deny", "rule": deny.ruleID.rawValue]
        case .indeterminate(let reason): return ["decision": "indeterminate", "rule": "\(reason)"]
        }
    }

    func describe(_ timed: Timed) -> [String: Any] {
        switch timed.run {
        case .verdict(let v):
            let t = JudgeRuntime.thresholds(provenance: .unknown)
            var action = v.action(blockThreshold: t.block, reviewThreshold: t.review)
            if v.truncated, action == .allow { action = .review }
            return [
                "run": "verdict", "choice": v.choice.rawValue, "action": action.rawValue,
                "pAllow": v.probabilities[.allow] ?? -1, "pReview": v.probabilities[.review] ?? -1,
                "pBlock": v.probabilities[.block] ?? -1, "risk": v.risk, "malicious": v.malicious,
                "truncated": v.truncated, "inferMs": v.latencyMilliseconds, "wallMs": timed.wallMs,
            ]
        default:
            return ["run": "\(timed.run)", "wallMs": timed.wallMs]
        }
    }

    func seedWorkspace(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("tests"), withIntermediateDirectories: true)
        let files: [String: String] = [
            "package.json": #"{"name":"app","version":"1.4.1","scripts":{"build":"tsc -p .","dev":"vite","test":"vitest run","test:unit":"vitest run","test:e2e":"playwright test","lint":"eslint .","typecheck":"tsc --noEmit"},"dependencies":{"react":"^19.0.0"}}"#,
            "Package.swift": "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n",
            "Sources/App/main.swift": "print(\"hi\")\n",
            "src/index.ts": "export const x = 1\n",
            "Makefile": "build:\n\tswift build\ntest:\n\tswift test\nlint:\n\tswiftlint\nclean:\n\trm -rf .build\n",
            "pyproject.toml": "[project]\nname = \"app\"\nversion = \"1.4.1\"\n",
            "go.mod": "module example.com/app\n\ngo 1.23\n",
            "Cargo.toml": "[package]\nname = \"app\"\nversion = \"1.4.1\"\n",
            "README.md": "# app\n",
            ".gitignore": ".build/\nnode_modules/\n",
            "tests/test_api.py": "def test_ok():\n    assert True\n",
        ]
        for (path, body) in files {
            try body.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
    }

    func git(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func writeMeta(_ meta: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: Self.outDir.appendingPathComponent("meta.json"))
    }

    /// Removes the eval's private compiled copy (keyed by the symlink path)
    /// afterwards. Mirrors RVLaya's `CompiledModelStore` layout: entries
    /// live in `CoreMLGuard.processStateRoot()/models` (`$HOME/.config/rv/
    /// cache/laya/models`) as `<fnv1a(package path)>-<version>.mlmodelc`
    /// plus a `.manifest.json`, with `.partial-` staging copies prefixed
    /// `.<fnv1a(package path)>-`.
    func removeCompiledCache(for bundle: URL) {
        let fm = FileManager.default
        let package = bundle.appendingPathComponent("model.mlpackage")
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") else { return }
        let models = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config/rv/cache/laya/models", isDirectory: true)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in package.path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let key = String(hash, radix: 16)
        guard let names = try? fm.contentsOfDirectory(atPath: models.path) else { return }
        for name in names where name.hasPrefix("\(key)-") || name.hasPrefix(".\(key)-") {
            try? fm.removeItem(at: models.appendingPathComponent(name))
        }
    }
}

/// Serves the model-only run already computed for this exact
/// (command, context) back to the door, and records that the door asked.
private final class RecordingJudge: JudgePort, @unchecked Sendable {
    private let lock = NSLock()
    private var primed: [String: JudgeRuntime.JudgeRun] = [:]
    private var called = false

    private static func key(_ command: String, _ lines: [String]) -> String {
        command + "\u{1}" + lines.joined(separator: "\u{2}")
    }

    func prime(command: String, lines: [String], run: JudgeRuntime.JudgeRun) {
        lock.withLock { primed = [Self.key(command, lines): run]; called = false }
    }

    func takeCalled() -> Bool {
        lock.withLock { defer { called = false }; return called }
    }

    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        let hit = lock.withLock { () -> JudgeRuntime.JudgeRun? in
            called = true
            return primed[Self.key(call.command, call.context.lines())]
        }
        if let hit { return hit }
        return JudgeRuntime.runJudge(
            command: call.command, context: call.context, engine: call.engine, bundle: call.bundle, wait: nil)
    }
}
