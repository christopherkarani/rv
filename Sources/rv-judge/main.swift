import Foundation
import RVLaya

// rv-judge --bundle DIR 'command' ...   (or commands on stdin, one per line)
// Emits one JSON verdict per command. The bench harness in Scripts/laya
// drives this; humans use `rv test` for the full guard.
//
// RV_FT_BUNDLE=DIR selects the single-pass fine-tuned judge (Ticket 5a
// bundle with model.mlpackage + tokenizer.json + config.json) instead of
// the three-question LayaCoreMLJudge. RV_JUDGE_TOUCHED="a/,b/" feeds an
// agent-touched context list to the fine-tuned judge (testing hook).

#if canImport(CoreML)
var args = Array(CommandLine.arguments.dropFirst())
var bundlePath: String?
if let i = args.firstIndex(of: "--bundle"), i + 1 < args.count {
    bundlePath = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
bundlePath = bundlePath
    ?? ProcessInfo.processInfo.environment["RV_LAYA_BUNDLE"]
    ?? ProcessInfo.processInfo.environment["RV_FT_BUNDLE"]
guard let bundlePath else {
    FileHandle.standardError.write(Data("usage: rv-judge --bundle DIR 'command' ...\n".utf8))
    exit(2)
}
do {
    let runJudge: (String) throws -> LayaVerdict
    if let ftBundle = ProcessInfo.processInfo.environment["RV_FT_BUNDLE"],
       !ftBundle.isEmpty {
        let judge = try FineTunedJudge(bundleDir: URL(fileURLWithPath: ftBundle))
        let touched = (ProcessInfo.processInfo.environment["RV_JUDGE_TOUCHED"] ?? "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let context = JudgeContext(agentTouched: touched)
        runJudge = { try judge.judge($0, context: context) }
    } else {
        let judge = try LayaCoreMLJudge(bundleDir: URL(fileURLWithPath: bundlePath))
        runJudge = { try judge.judge($0) }
    }
    var commands = args
    if commands.isEmpty {
        let stdinText = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        commands = stdinText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for command in commands {
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
        row["probabilities"] = verdict.probabilities.mapValues { ($0 * 10000).rounded() / 10000 }
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
} catch {
    FileHandle.standardError.write(Data("rv-judge: \(error)\n".utf8))
    exit(1)
}
#else
FileHandle.standardError.write(Data("rv-judge: CoreML unavailable on this platform\n".utf8))
exit(1)
#endif
