import Foundation
import RVLaya

// rv-judge [--ft|--stock] --bundle DIR 'command' ...   (or commands on
// stdin, one per line). Emits one JSON verdict per command; per-command
// failures emit an {"error": ...} row and the exit code turns non-zero
// after the batch. The bench harness in Scripts/laya drives this;
// humans use `rv test` for the full guard.
//
// Engine selection precedence (explicit always beats environment):
// --ft/--stock flag > RV_FT_BUNDLE (fine-tuned) > --bundle/RV_LAYA_BUNDLE
// (stock). Passing both --ft and a bundle means the bundle is the FT
// bundle. RV_JUDGE_TOUCHED="a/,b/" feeds an agent-touched context list
// to the fine-tuned judge (testing hook).

#if canImport(CoreML)
func failUsage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("rv-judge: \(message)\nusage: rv-judge [--ft|--stock] --bundle DIR 'command' ...\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var bundlePath: String?
var wantFT: Bool?
if let i = args.firstIndex(of: "--ft") {
    wantFT = true
    args.remove(at: i)
}
if let i = args.firstIndex(of: "--stock") {
    if wantFT == true { failUsage("pass only one of --ft and --stock") }
    wantFT = false
    args.remove(at: i)
}
if let i = args.firstIndex(of: "--bundle") {
    guard i + 1 < args.count else { failUsage("--bundle requires a directory") }
    bundlePath = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let env = ProcessInfo.processInfo.environment
let useFT: Bool
let resolvedBundle: String
switch wantFT {
case .some(true):
    useFT = true
    guard let path = bundlePath ?? env["RV_FT_BUNDLE"], !path.isEmpty else {
        failUsage("--ft requires --bundle DIR or RV_FT_BUNDLE")
    }
    resolvedBundle = path
case .some(false):
    useFT = false
    guard let path = bundlePath ?? env["RV_LAYA_BUNDLE"], !path.isEmpty else {
        failUsage("--stock requires --bundle DIR or RV_LAYA_BUNDLE")
    }
    resolvedBundle = path
case .none:
    if let path = bundlePath {
        // An explicit bundle without an engine flag is stock, matching
        // the pre-FT CLI. RV_FT_BUNDLE must not silently override it.
        useFT = false
        resolvedBundle = path
    } else if let ft = env["RV_FT_BUNDLE"], !ft.isEmpty {
        useFT = true
        resolvedBundle = ft
    } else if let stock = env["RV_LAYA_BUNDLE"], !stock.isEmpty {
        useFT = false
        resolvedBundle = stock
    } else {
        failUsage("no bundle given")
    }
}
do {
    let runJudge: (String) throws -> LayaVerdict
    if useFT {
        let judge = try FineTunedJudge(bundleDir: URL(fileURLWithPath: resolvedBundle))
        let touched = (env["RV_JUDGE_TOUCHED"] ?? "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let context = JudgeContext(agentTouched: touched)
        runJudge = { try judge.judge($0, context: context) }
    } else {
        let judge = try LayaCoreMLJudge(bundleDir: URL(fileURLWithPath: resolvedBundle))
        runJudge = { try judge.judge($0) }
    }
    var commands = args
    if commands.isEmpty {
        let stdinText = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        commands = stdinText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
    var failures = 0
    for command in commands {
        do {
            let verdict = try runJudge(command)
            var row: [String: Any] = [
                "command": command,
                "choice": verdict.choice,
                "action": verdict.action().rawValue,
                "risk": (verdict.risk * 1000).rounded() / 1000,
                "malicious": (verdict.malicious * 10000).rounded() / 10000,
                "risk_score": (verdict.riskScore * 10000).rounded() / 10000,
                "ms": (verdict.latencyMilliseconds * 10).rounded() / 10,
                "checkpoint": verdict.checkpoint,
            ]
            if verdict.truncated { row["truncated"] = true }
            row["probabilities"] = verdict.probabilities.mapValues { ($0 * 10000).rounded() / 10000 }
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            failures += 1
            let row: [String: Any] = ["command": command, "error": "\(error)"]
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
        }
    }
    if failures > 0 { exit(1) }
} catch {
    FileHandle.standardError.write(Data("rv-judge: \(error)\n".utf8))
    exit(1)
}
#else
FileHandle.standardError.write(Data("rv-judge: CoreML unavailable on this platform\n".utf8))
exit(1)
#endif
