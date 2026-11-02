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
        guard segments.count > 1 else { return nil }
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
    guard splitSegments(view).count > 1,
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
    let outcome = ShellPipeline.unwrap(
        segment,
        workingDirectory: nil,
        budget: .default,
        depth: 0,
        layers: [],
        splitChains: false
    )
    guard case .complete(let unwrapped) = outcome, unwrapped.layers.isEmpty == false,
        unwrapped.workingDirectory == nil
    else {
        return [segment]
    }
    return splitSegments(unwrapped.command.rawValue)
}
