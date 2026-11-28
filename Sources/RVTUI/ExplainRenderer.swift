import RVDomain
import RVPresentation
import RVTheme

public struct ExplainRenderer: FrameRenderer {
    public init() {}

    public func render(_ model: ExplainViewModel, palette: Palette) -> [String] {
        var children: [OutlineItem] = [decisionItem(model, palette: palette)]
        if let note = model.observeNote {
            children.append(.leaf(label: observeNoteLabel, value: note, emphasis: .plain))
        }
        children += [
            .group(
                label: "Command",
                emphasis: .heading,
                children: [
                    .leaf(label: "Input", value: DisplayedText.field(model.command.rawValue), emphasis: .fact),
                ]
            ),
        ]

        if let semantic = semanticItems(model) {
            children.append(.group(label: "Semantic", emphasis: .heading, children: semantic))
        }

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
                        .leaf(label: step.label, value: step.displayOutcome, emphasis: .muted)
                    }
                )
            )
        }

        if !model.suggestions.isEmpty {
            children.append(
                .group(label: "Suggestions", emphasis: .mark, children: suggestionItems(model))
            )
        }

        if !model.alsoMatches.isEmpty {
            children.append(
                .group(
                    label: "Also matches",
                    emphasis: .mark,
                    children: model.alsoMatches.map { .leaf(label: $0.label, value: $0.display, emphasis: .plain) }
                )
            )
        }

        if !model.offPacks.isEmpty {
            children.append(
                .group(
                    label: "Packs that are off",
                    emphasis: .mark,
                    children: model.offPacks.map {
                        .group(label: $0.display, emphasis: .plain, children: [.text("$ \($0.turnOn)", emphasis: .fact)])
                    }
                )
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

/// `Decision: BLOCKED` in the verdict's tone; an observe verdict
/// (`Decision: ◐ Would stop`, `Decision: ✕ Stopped, in every mode`)
/// paints only its glyph, in the glyph's ink, and the words bold.
private func decisionItem(_ model: ExplainViewModel, palette: Palette) -> OutlineItem {
    let words = model.explainDecisionWord
    guard model.observeDecisionWords != nil, leadsWithGlyph(words) else {
        return .text("Decision: \(words)", emphasis: outlineEmphasis(model.decisionTone))
    }
    return .painted("Decision: " + paintLeadingGlyph(words, rest: palette.fact, palette: palette))
}

private func semanticItems(_ model: ExplainViewModel) -> [OutlineItem]? {
    guard let semantic = model.semantic else { return nil }
    var items: [OutlineItem] = [
        .leaf(label: "Action", value: semantic.action, emphasis: .fact),
        .leaf(label: "Scope", value: semantic.scope, emphasis: .plain),
    ]
    if let effect = semantic.effect {
        items.append(.leaf(label: "Effect", value: effect, emphasis: .fact))
    }
    if let remote = semantic.remote {
        items.append(.leaf(label: "Remote", value: DisplayedText.field(remote), emphasis: .plain))
    }
    if let ref = semantic.ref {
        items.append(.leaf(label: "Ref", value: DisplayedText.field(ref), emphasis: .plain))
    }
    if let pathspec = semantic.pathspec {
        items.append(.leaf(label: "Pathspec", value: DisplayedText.field(pathspec), emphasis: .plain))
    }
    if let path = semantic.path {
        items.append(.leaf(label: "Path", value: DisplayedText.field(path), emphasis: .plain))
    }
    if let kind = semantic.kind {
        items.append(.leaf(label: "Kind", value: kind, emphasis: .fact))
    }
    if let category = semantic.category {
        items.append(.leaf(label: "Category", value: category, emphasis: .fact))
    }
    if let catalogRule = semantic.catalogRule {
        items.append(.leaf(label: "Catalog", value: catalogRule, emphasis: .plain))
    }
    if let wrappers = semantic.wrappers, wrappers.isEmpty == false {
        items.append(
            .leaf(label: "Wrappers", value: wrappers.joined(separator: " → "), emphasis: .plain)
        )
    }
    return items
}

private func matchItems(_ model: ExplainViewModel) -> [OutlineItem]? {
    if model.decisionTone == .incomplete {
        return nil
    }
    var match: [OutlineItem] = []
    if let rule = model.ruleDisplay {
        match.append(.leaf(label: "Rule", value: DisplayedText.field(rule), emphasis: .fact))
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
        let label = "\(suggestion.kind.title): \(suggestion.text)"
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

// MARK: - rv why <code>

/// `rv why <code>`: the anatomy of a stop (North Star v2): verdict and
/// command on one line, the only colour on screen; then why, the rule, a
/// safer command, who acts; the next command last.
public struct DecisionStoryRenderer: FrameRenderer {
    static let pad = "  "
    static let labelWidth = 8

    public init() {}

    public func render(_ story: DecisionStory, palette: Palette) -> [String] {
        let ink = story.outcome == .stopped ? palette.deny : palette.mark
        let verdict = story.outcome.label
        let indent = String(repeating: " ", count: verdict.count + 3)
        var lines = [
            "",
            paint(verdict, slot: ink, reset: palette.reset) + "   " + paint(story.command, slot: palette.fact, reset: palette.reset),
            indent + paint(story.context, slot: palette.silver, reset: palette.reset),
            "",
            row("why", story.why, palette: palette),
            row("rule", story.rule, palette: palette),
        ]
        switch story.outcome {
        case .stopped:
            if story.holdsInEveryMode {
                lines.append(row("holds", "in every mode, watching too", palette: palette))
            }
        case .wouldStop:
            lines.append(row("ran", "watch mode let it run; guarding would stop it", palette: palette))
        case .wouldAsk:
            lines.append(row("ran", "watch mode let it run; guarding would ask you first", palette: palette))
        }
        if let safer = story.safer {
            lines.append(row("safer", paint(safer, slot: palette.heading, reset: palette.reset), palette: palette))
        }
        if let who = story.who {
            lines.append(row("who", who, palette: palette))
        }
        if story.commandMissing {
            lines.append(row("note", paint("rvd kept no command text for this one", slot: palette.silver, reset: palette.reset), palette: palette))
        }
        lines += [
            "",
            paint("\(CommandVocabulary.Glyph.next.rawValue) \(DecisionStory.nextCommand)", slot: palette.heading, reset: palette.reset)
                + "   " + paint("every decision this week", slot: palette.silver, reset: palette.reset),
        ]
        return lines.map { $0.isEmpty ? $0 : Self.pad + $0 }
    }

    /// `rv why <code>` for a code no row has.
    public func renderNotFound(code: String, palette: Palette) -> [String] {
        [
            "",
            paint(CommandVocabulary.Glyph.stopped.rawValue, slot: palette.deny, reset: palette.reset)
                + " No decision \(DisplayedText.field(code)) in rv's log this week.",
            "",
            paint("\(CommandVocabulary.Glyph.next.rawValue) \(DecisionStory.nextCommand)", slot: palette.heading, reset: palette.reset)
                + "   " + paint("find its code", slot: palette.silver, reset: palette.reset),
        ].map { $0.isEmpty ? $0 : Self.pad + $0 }
    }

    private func row(_ label: String, _ body: String, palette: Palette) -> String {
        paint(padRight(label, to: Self.labelWidth), slot: palette.silver, reset: palette.reset) + body
    }
}
