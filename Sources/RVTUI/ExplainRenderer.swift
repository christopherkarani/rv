import RVPresentation
import RVTheme

public struct ExplainRenderer: FrameRenderer {
    public init() {}

    public func render(_ model: ExplainViewModel, palette: Palette) -> [String] {
        var children: [OutlineItem] = [
            .text(
                "Decision: \(model.explainDecisionWord)",
                emphasis: outlineEmphasis(model.decisionTone)
            ),
            .group(
                label: "Command",
                emphasis: .heading,
                children: [
                    .leaf(label: "Input", value: model.command.rawValue, emphasis: .fact),
                ]
            ),
        ]

        if let match = matchItems(model) {
            children.append(.group(label: "Match", emphasis: .mark, children: match))
        }

        if model.decisionTone == .incomplete {
            children.append(.leaf(label: "Reason", value: model.fact, emphasis: .plain))
        }

        if let notes = explanationItems(model) {
            children.append(.group(label: "Explanation", emphasis: .plain, children: notes))
        }

        if !model.steps.isEmpty {
            children.append(
                .group(
                    label: "Pipeline",
                    emphasis: .trace,
                    children: model.steps.map { step in
                        .leaf(label: step.name, value: step.outcome, emphasis: .muted)
                    }
                )
            )
        }

        if !model.suggestions.isEmpty {
            children.append(
                .group(label: "Suggestions", emphasis: .mark, children: suggestionItems(model))
            )
        }

        if let next = model.nextAction {
            children.append(.leaf(label: "Next", value: next, emphasis: .plain))
        }

        return renderTree(
            root: model.heading,
            emphasis: .plain,
            children: children,
            palette: palette
        )
    }
}

private func matchItems(_ model: ExplainViewModel) -> [OutlineItem]? {
    if model.decisionTone == .incomplete {
        return nil
    }
    var match: [OutlineItem] = []
    if let rule = model.ruleDisplay {
        match.append(.leaf(label: "Rule", value: rule, emphasis: .fact))
    }
    if let pack = model.packDisplay {
        match.append(.leaf(label: "Pack", value: pack, emphasis: .plain))
    }
    if let pattern = model.patternName {
        match.append(.leaf(label: "Pattern", value: pattern, emphasis: .plain))
    }
    if let regex = model.regex {
        match.append(.regex(label: "Regex", pattern: regex))
    }
    if let severity = model.severityDisplay {
        match.append(.leaf(label: "Severity", value: severity, emphasis: .fact))
    }
    if model.decisionTone == .deny {
        match.append(.leaf(label: "Reason", value: model.fact, emphasis: .plain))
    }
    return match.isEmpty ? nil : match
}

private func explanationItems(_ model: ExplainViewModel) -> [OutlineItem]? {
    guard let explanation = model.explanation else { return nil }
    let notes = explanationLines(from: explanation)
    if notes.isEmpty { return nil }
    return notes.map { note in
        note.isEmpty ? .spacer : .text(note, emphasis: .plain)
    }
}

private func suggestionItems(_ model: ExplainViewModel) -> [OutlineItem] {
    model.suggestions.map { suggestion in
        var children: [OutlineItem] = []
        if let command = suggestion.command {
            children.append(.text("$ \(command)", emphasis: .fact))
        }
        if let url = suggestion.url {
            children.append(.text("See: \(url)", emphasis: .muted))
        }
        let label = "\(suggestion.kind): \(suggestion.text)"
        if children.isEmpty {
            return .text(label, emphasis: .plain)
        }
        return .group(label: label, emphasis: .plain, children: children)
    }
}

private func outlineEmphasis(_ tone: DecisionTone) -> OutlineEmphasis {
    switch tone {
    case .allow:
        return .allow
    case .deny:
        return .deny
    case .incomplete:
        return .fact
    }
}
