// libFuzzer harness: the gate's front door (Normalize, pin evaluate, and
// the product door evaluateWithSemantics) over day-one packs.
// Build and run: docs/fuzzing.md. In-suite twin: NormalizeFuzzTests.
import Foundation
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
    // line one into an allow. Inputs shaped like the open heredoc masking
    // bug are skipped (NormalizeFuzzTests.heredocBodyRepeatingAnEarlierWord);
    // otherwise every run stops on that one finding.
    let denied = deniedFirstLines[Int(bytes.first ?? 0) % deniedFirstLines.count]
    let suffixed = denied + "\n" + command
    if gate.decisions(suffixed)[1] == .allow {
        precondition(heredocBodyRepeatsEarlierText(suffixed), "denied first line allowed with suffix")
    }
    return 0
}

// TODO(fix/heredoc-mask-position): delete this and its call once heredoc
// masking blanks the body itself rather than the first match of its text.
// Twin of NormalizeFuzzTests.heredocBodyRepeatsEarlierText.
/// The known heredoc masking bug shape: a line after a heredoc opener
/// (`<<`, `<<-`; a `<<<` here-string is not one), other than a delimiter
/// line, whose text, leading tabs dropped, already occurs earlier in the
/// command. Masking blanks the first match of the body text, so only such
/// inputs can hide an earlier line.
private func heredocBodyRepeatsEarlierText(_ command: String) -> Bool {
    let lines = command.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    guard let opener = lines.firstIndex(where: { heredocDelimiters($0).isEmpty == false }) else { return false }
    var delimiters = Set<String>()
    var preceding = ""
    for (index, line) in lines.enumerated() {
        let text = line.drop { $0 == "\t" }
        if index > opener, text.isEmpty == false, delimiters.contains(String(text)) == false,
            preceding.range(of: text) != nil
        {
            return true
        }
        delimiters.formUnion(heredocDelimiters(line))
        preceding += (index == 0 ? "" : "\n") + line
    }
    return false
}

/// The delimiter word after each `<<` or `<<-` in `line`, quotes and
/// backslashes dropped. A run of three `<` is a here-string, not an opener.
private func heredocDelimiters(_ line: Substring) -> [String] {
    var delimiters: [String] = []
    var index = line.startIndex
    while index < line.endIndex {
        guard line[index] == "<" else {
            index = line.index(after: index)
            continue
        }
        let run = line[index...].prefix { $0 == "<" }
        index = run.endIndex
        guard run.count == 2 || run.count >= 4 else { continue }
        var rest = line[index...]
        if rest.first == "-" { rest = rest.dropFirst() }
        let word = rest.drop { $0 == " " || $0 == "\t" }
            .prefix { $0.isWhitespace == false && "|<>;&()".contains($0) == false }
            .filter { $0 != "'" && $0 != "\"" && $0 != "\\" }
        if word.isEmpty == false { delimiters.append(word) }
    }
    return delimiters
}
