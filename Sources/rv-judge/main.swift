import Foundation
import RVLaya

// rv-judge --bundle DIR 'command' ...   (or commands on stdin, one per line)
// Emits one JSON verdict per command. The bench harness in Scripts/laya
// drives this; humans use `rv test` for the full guard.

#if canImport(CoreML)
var args = Array(CommandLine.arguments.dropFirst())
var bundlePath: String?
if let i = args.firstIndex(of: "--bundle"), i + 1 < args.count {
    bundlePath = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
bundlePath = bundlePath ?? ProcessInfo.processInfo.environment["RV_LAYA_BUNDLE"]
guard let bundlePath else {
    FileHandle.standardError.write(Data("usage: rv-judge --bundle DIR 'command' ...\n".utf8))
    exit(2)
}
do {
    let judge = try LayaCoreMLJudge(bundleDir: URL(fileURLWithPath: bundlePath))
    var commands = args
    if commands.isEmpty {
        let stdinText = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        commands = stdinText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for command in commands {
        let verdict = try judge.judge(command)
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
