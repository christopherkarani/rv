import Foundation
import RVDomain

extension ShellPipeline {
    /// Unwraps every segment of a chain (`a && sudo b`, `a | xargs b`), not
    /// just the first. Returns nil when no segment is a wrapper, so the
    /// whole-text path keeps its exact pre-chain behavior. When a later
    /// segment peels, the result is the segments rejoined with `;`, each
    /// replaced by its inner command; any limited segment limits the chain.
    static func unwrapChain(
        _ text: String,
        workingDirectory: WorkingDirectory?,
        budget: UnwrapBudget,
        depth: Int,
        layers: [WrapperKind]
    ) -> UnwrapOutcome? {
        let segments = splitSegments(maskNonExecutingHeredocBodies(text))
        // A single segment still differs from the text when a head was
        // stripped (`time sudo rm -r ~`), so its wrappers peel too.
        guard segments.count > 1 || segments.first != text else { return nil }
        var rewritten: [String] = []
        var peeledLayers: [WrapperKind] = []
        var changed = false
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == text { continue }
            let outcome = unwrap(
                trimmed,
                workingDirectory: workingDirectory,
                budget: budget,
                depth: depth,
                layers: [],
                splitChains: false
            )
            switch outcome {
            case .limited(let kinds):
                return .limited(layers: layers + peeledLayers + kinds)
            case .complete(let unwrapped):
                if unwrapped.layers.isEmpty {
                    rewritten.append(trimmed)
                    continue
                }
                if unwrapped.workingDirectory != workingDirectory {
                    return .limited(layers: layers + peeledLayers + unwrapped.layers)
                }
                changed = true
                peeledLayers += unwrapped.layers
                rewritten.append(unwrapped.command.rawValue)
            }
        }
        guard changed else { return nil }
        return .complete(
            UnwrappedCommand(
                command: ShellCommand(rawValue: rewritten.joined(separator: " ; ")),
                layers: layers + peeledLayers,
                workingDirectory: workingDirectory
            )
        )
    }
}

/// The matching view of a command, extended on chains with the matching view
/// of its unwrapped form. A later `bash -c '...'` segment has its payload
/// masked in the matching view; the unwrapped text carries the real inner
/// command, so segment parsers see both.
func chainSegmentView(of command: ShellCommand) -> String {
    let view = Normalize.matchingView(of: command.rawValue).rawValue
    let segments = splitSegments(view)
    guard segments.count > 1 || segments.first != view.trimmingCharacters(in: .whitespacesAndNewlines),
        case .complete(let unwrapped) = unwrapCommand(command),
        unwrapped.layers.isEmpty == false,
        unwrapped.command.rawValue != command.rawValue
    else {
        return view
    }
    return view + " ; " + unwrapped.command.rawValue
}

/// A chain segment after peeling its own wrappers (`sudo rm -r ~` becomes
/// `rm -r ~`), re-split because the inner text may itself chain. Segments
/// that do not peel cleanly come back unchanged.
func peeledSegments(_ segment: String) -> [String] {
    peeledSegments(segment, outcome: segmentUnwrap(segment))
}

/// `peeledSegments`, plus the commands an `xargs` runs where the unwrap
/// stops at it (an inner verb that writes, nesting past `maxNestedXargs`).
/// xargs still runs them, so a reader that must see every program
/// (`git -c core.fsmonitor=…`, an alias) reads them lexically: the words
/// after each `xargs` and its options, also inside a quoted `-c` script.
func peeledSegmentsReadingXargs(_ segment: String) -> [String] {
    let outcome = segmentUnwrap(segment)
    guard case .limited(let layers) = outcome, layers.contains(.xargs) else {
        return peeledSegments(segment, outcome: outcome)
    }
    return [segment] + xargsInnerCommands(segment, nesting: 0)
}

private func segmentUnwrap(_ segment: String) -> UnwrapOutcome {
    ShellPipeline.unwrap(
        segment,
        workingDirectory: nil,
        budget: .default,
        depth: 0,
        layers: [],
        splitChains: false
    )
}

private func peeledSegments(_ segment: String, outcome: UnwrapOutcome) -> [String] {
    guard case .complete(let unwrapped) = outcome, unwrapped.layers.isEmpty == false,
        unwrapped.workingDirectory == nil
    else {
        return [segment]
    }
    return splitSegments(unwrapped.command.rawValue)
}

/// Quoted words read as scripts (`bash -c "… xargs …"`), at most this deep.
private let maxXargsScriptNesting = 2

private func xargsInnerCommands(_ text: String, nesting: Int) -> [String] {
    var inner: [String] = []
    for segment in splitSegments(text) {
        let tokens = ShellPipeline.tokenize(segment).filter { $0.isNewline == false }
        let words = tokens.map(\.lexeme)
        // Past the cap the unwrap is limited anyway; reading the first
        // xargs words keeps this linear in the segment.
        let launchers = words.indices.lazy.filter { isXargsName(words[$0]) }.prefix(maxNestedXargs + 1)
        for index in launchers {
            // Options it cannot walk leave no program to read; the unwrap
            // already limited the segment, which enforce denies.
            guard let start = parseXargsOptions(Array(words[(index + 1)...]))?.programStart else { continue }
            inner.append(contentsOf: peeledSegments(renderCommand(Array(tokens[(index + 1 + start)...]))))
        }
        if nesting < maxXargsScriptNesting {
            for word in words where word.contains(where: \.isWhitespace) {
                inner.append(contentsOf: xargsInnerCommands(word, nesting: nesting + 1))
            }
        }
    }
    return inner
}
