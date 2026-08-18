import Foundation

public func explanationLines(from raw: String) -> [String] {
    var lines: [String] = []
    for paragraph in raw.split(separator: "\n", omittingEmptySubsequences: false) {
        let cleaned = collapseSpaces(String(paragraph).replacingOccurrences(of: "\\", with: " "))
        if cleaned.isEmpty {
            if let last = lines.last, !last.isEmpty {
                lines.append("")
            }
            continue
        }
        lines.append(contentsOf: splitMarkedBullets(String(paragraph)))
    }
    if lines.last == "" {
        lines.removeLast()
    }
    return lines
}

private let bulletMarker = "\\ - "

private func splitMarkedBullets(_ paragraph: String) -> [String] {
    var parts: [String] = []
    var rest = paragraph
    while let range = rest.range(of: bulletMarker) {
        parts.append(String(rest[..<range.lowerBound]))
        rest = String(rest[range.upperBound...])
    }
    parts.append(rest)

    var lines: [String] = []
    if let head = parts.first {
        let trimmed = stripMarkdownInline(flattenWrap(head))
        if !trimmed.isEmpty {
            lines.append(trimmed)
        }
    }
    for part in parts.dropFirst() {
        let item = stripMarkdownInline(flattenWrap(part))
        if !item.isEmpty {
            lines.append("• \(item)")
        }
    }
    return lines
}

private func stripMarkdownInline(_ text: String) -> String {
    stripInlineMarkup(rewriteMarkdownLinks(text))
}

private func rewriteMarkdownLinks(_ text: String) -> String {
    var rest = text
    var out = ""
    while let open = rest.firstIndex(of: "[") {
        let afterOpen = rest.index(after: open)
        guard let close = rest[afterOpen...].firstIndex(of: "]") else { break }
        let afterClose = rest.index(after: close)
        guard afterClose < rest.endIndex, rest[afterClose] == "(" else {
            out.append(contentsOf: rest[...open])
            rest = String(rest[afterOpen...])
            continue
        }
        let urlStart = rest.index(after: afterClose)
        guard let urlEnd = rest[urlStart...].firstIndex(of: ")") else {
            out.append(contentsOf: rest[...open])
            rest = String(rest[afterOpen...])
            continue
        }
        let isImage = open > rest.startIndex && rest[rest.index(before: open)] == "!"
        let prefixEnd = isImage ? rest.index(before: open) : open
        out.append(contentsOf: rest[..<prefixEnd])
        let label = stripInlineMarkup(String(rest[afterOpen..<close]))
        let url = String(rest[urlStart..<urlEnd])
        if isImage || url.isEmpty {
            out.append(label)
        } else {
            out.append("\(label) (\(url))")
        }
        rest = String(rest[rest.index(after: urlEnd)...])
    }
    out.append(rest)
    return out
}

private func stripInlineMarkup(_ text: String) -> String {
    var out = ""
    var index = text.startIndex
    while index < text.endIndex {
        if text[index...].hasPrefix("**") {
            index = text.index(index, offsetBy: 2)
            continue
        }
        if text[index] == "`" {
            index = text.index(after: index)
            continue
        }
        out.append(text[index])
        index = text.index(after: index)
    }
    return out
}

private func flattenWrap(_ text: String) -> String {
    collapseSpaces(text.replacingOccurrences(of: "\\", with: " "))
}

private func collapseSpaces(_ text: String) -> String {
    var out = ""
    var seenSpace = false
    for character in text {
        if character.isWhitespace {
            if !seenSpace {
                out.append(" ")
                seenSpace = true
            }
        } else {
            out.append(character)
            seenSpace = false
        }
    }
    return out.trimmingCharacters(in: .whitespaces)
}
