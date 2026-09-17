import Testing
import RVPresentation
import RVTheme
@testable import RVTUI

@Test func paint_emptySlotIsIdentity() {
    #expect(paint("core.git", slot: "", reset: "X") == "core.git")
    #expect(paint("core.git", slot: "[", reset: "]") == "[core.git]")
}

@Test func padRight_growsShortTextAndKeepsWide() {
    #expect(padRight("git", to: 6) == "git   ")
    #expect(padRight("filesystem", to: 4) == "filesystem")
}

@Test func wrapLine_emptyHardCutAndWhitespaceRemainder() {
    #expect(wrapLine("") == [""])
    #expect(wrapLine("short", width: 80) == ["short"])
    #expect(wrapLine("abcdefghij", width: 4) == ["abcd", "efgh", "ij"])
    #expect(wrapLine("one two three four", width: 8) == ["one two", "three", "four"])
    #expect(wrapLine("hello     ", width: 5) == ["hello"])
}

@Test func tokenizeRegex_coversEscapePosixAndLiteralRuns() {
    #expect(tokenizeRegex("").isEmpty)
    #expect(tokenizeRegex("\\") == [RegexSpan(text: "\\", kind: .escape)])
    #expect(tokenizeRegex("[") == [RegexSpan(text: "[", kind: .meta)])
    #expect(tokenizeRegex("[:]") == [
        RegexSpan(text: "[", kind: .meta),
        RegexSpan(text: ":", kind: .literal),
        RegexSpan(text: "]", kind: .meta),
    ])
    #expect(tokenizeRegex("[:x") == [
        RegexSpan(text: "[", kind: .meta),
        RegexSpan(text: ":x", kind: .literal),
    ])
    #expect(tokenizeRegex("[:alnum") == [
        RegexSpan(text: "[", kind: .meta),
        RegexSpan(text: ":alnum", kind: .literal),
    ])
    #expect(tokenizeRegex("[:alnum:") == [
        RegexSpan(text: "[", kind: .meta),
        RegexSpan(text: ":alnum:", kind: .literal),
    ])
    let ok = tokenizeRegex("[[:alnum:]]")
    #expect(ok.contains { $0.kind == .posixName && $0.text == "alnum" })
    #expect(tokenizeRegex("aa") == [RegexSpan(text: "aa", kind: .literal)])
}

@Test func paintedRegex_emptyAndColorSlots() {
    #expect(paintedRegex("", palette: colorOffPalette) == "")
    #expect(paintedRegexLines("", width: 8, palette: colorOffPalette) == [""])
    let on = Palette(for: ColorCapability(colorsEnabled: true))
    let painted = paintedRegex(#"a\s[[:digit:]]+"#, palette: on)
    #expect(painted.contains(on.regex.escape))
    #expect(painted.contains(on.regex.meta))
    #expect(painted.contains(on.regex.name))
    let wrapped = paintedRegexLines(String(repeating: "x", count: 6), width: 2, palette: on)
    #expect(wrapped.count == 3)
    let flushed = paintedRegexLines("aa[", width: 2, palette: colorOffPalette)
    #expect(flushed == ["aa", "["])
}

@Test func renderTree_coversEmphasisSpacerAndWrap() {
    let palette = Palette(for: ColorCapability(colorsEnabled: true))
    let long = String(repeating: "word ", count: 20)
    let lines = renderTree(
        root: "Root",
        emphasis: .plain,
        children: [
            .leaf(label: "Fact", value: long, emphasis: .fact),
            .regex(label: "Regex", pattern: String(repeating: "[a-z]", count: 24)),
            .text("muted", emphasis: .muted),
            .text("deny", emphasis: .deny),
            .text("allow", emphasis: .allow),
            .text("heading", emphasis: .heading),
            .text("mark", emphasis: .mark),
            .text("trace", emphasis: .trace),
            .group(
                label: "Group",
                emphasis: .heading,
                children: [
                    .spacer,
                    .text("child", emphasis: .plain),
                ]
            ),
        ],
        palette: palette
    )
    #expect(lines.first == "Root")
    #expect(lines.contains { $0.contains(palette.fact) })
    #expect(lines.contains { $0.contains(palette.deny) })
    #expect(lines.contains { $0.contains(palette.allow) })
    #expect(lines.contains { $0.contains(palette.heading) })
    #expect(lines.contains { $0.contains(palette.mark) })
    #expect(lines.contains { $0.contains(palette.trace) })
    #expect(lines.contains { $0.contains(palette.regex.meta) })
    #expect(lines.contains { stripCSI($0).trimmingCharacters(in: .whitespaces).hasSuffix("│") })
}

private func stripCSI(_ text: String) -> String {
    var out = ""
    var index = text.startIndex
    while index < text.endIndex {
        if text[index] == "\u{001B}" {
            index = text.index(after: index)
            if index < text.endIndex, text[index] == "[" {
                index = text.index(after: index)
                while index < text.endIndex, !text[index].isLetter {
                    index = text.index(after: index)
                }
                if index < text.endIndex {
                    index = text.index(after: index)
                }
            }
            continue
        }
        out.append(text[index])
        index = text.index(after: index)
    }
    return out
}
