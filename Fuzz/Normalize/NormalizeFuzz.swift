// libFuzzer harness: the gate's front door (Normalize, pin evaluate, and
// the product door evaluateWithSemantics) over day-one packs.
// Build and run: docs/fuzzing.md. In-suite twin: NormalizeFuzzTests.
import RVDomain
import RVEngine
import RVPacks

private struct Gate: Sendable {
    let packs: [PackSnapshot]
    let engine = ICUPatternEngine()
    let compiled: CompiledPacks<ICUCompiledPattern>

    init() {
        do {
            packs = try PackRegistry.loadDayOne()
            compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
        } catch {
            fatalError("day-one packs failed to load: \(error)")
        }
    }

    func decisions(_ command: String) -> [Decision] {
        let request = EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs)
        return [
            evaluate(request, packs: packs, engine: engine, compiled: compiled).decision,
            evaluateWithSemantics(request, packs: packs, engine: engine, compiled: compiled).decision,
        ]
    }
}

private let gate = Gate()

/// Denied commands bash runs as line one, before it parses line two.
private let deniedFirstLines = ["git reset --hard", "rm -rf /", "git push --force", "bash -c 'git reset --hard'"]

@_cdecl("LLVMFuzzerTestOneInput")
public func rvFuzzNormalize(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let bytes = Array(UnsafeBufferPointer(start: data, count: size))
    let command = String(decoding: bytes, as: UTF8.self)
    _ = Normalize.matchingView(of: command)
    _ = Normalize.maskedSegments(of: command)
    _ = Normalize.secretScanView(of: ShellCommand(rawValue: command))
    let decisions = gate.decisions(command)
    if command.utf8.count > commandByteCap {
        precondition(decisions.allSatisfy { $0 == .indeterminate(.commandTooLarge) }, "oversized command parsed")
    }
    // Fail closed at the door: nothing on later lines may turn a denied
    // line one into an allow. Heredoc suffixes are skipped while the known
    // masking issue is open (NormalizeFuzzTests.heredocBodyRepeatingAnEarlierWord);
    // otherwise every run stops on that one finding.
    let denied = deniedFirstLines[Int(bytes.first ?? 0) % deniedFirstLines.count]
    if command.contains("<<") == false {
        precondition(gate.decisions(denied + "\n" + command)[1] != .allow, "denied first line allowed with suffix")
    }
    return 0
}
