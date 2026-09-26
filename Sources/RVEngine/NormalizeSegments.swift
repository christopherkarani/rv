import Foundation

/// File-write / print heredocs are data. Executing sinks keep the body so
/// `cat <<EOF | bash` stays a pin true-positive.
func maskNonExecutingHeredocBodies(_ text: String) -> String {
    guard let heredoc = extractHeredoc(text), heredoc.body.isEmpty == false else {
        return text
    }
    if peelExecutingSink(text, workingDirectory: nil) != nil {
        return text
    }
    guard let range = text.range(of: heredoc.body) else {
        return text
    }
    return text.replacingCharacters(
        in: range,
        with: String(repeating: " ", count: heredoc.body.count)
    )
}

func splitSegments(_ text: String) -> [String] {
    var segments: [String] = []
    let utf8 = text.utf8
    var index = utf8.startIndex
    var segmentStart = index
    var quote: UInt8?

    func flush(upTo end: String.Index) {
        let trimmed = text[segmentStart..<end].trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            segments.append(String(trimmed))
        }
    }

    while index < utf8.endIndex {
        let byte = utf8[index]
        if let currentQuote = quote {
            if byte == currentQuote { quote = nil }
            utf8.formIndex(after: &index)
            continue
        }
        if byte == UInt8(ascii: "'") || byte == UInt8(ascii: "\"") {
            quote = byte
            utf8.formIndex(after: &index)
            continue
        }
        if byte == UInt8(ascii: "&"),
           utf8.index(after: index) < utf8.endIndex,
           utf8[utf8.index(after: index)] == UInt8(ascii: "&")
        {
            flush(upTo: index)
            index = utf8.index(after: utf8.index(after: index))
            segmentStart = index
            continue
        }
        if byte == UInt8(ascii: "|"),
           utf8.index(after: index) < utf8.endIndex,
           utf8[utf8.index(after: index)] == UInt8(ascii: "|")
        {
            flush(upTo: index)
            index = utf8.index(after: utf8.index(after: index))
            segmentStart = index
            continue
        }
        if byte == UInt8(ascii: ";") || byte == UInt8(ascii: "|") {
            flush(upTo: index)
            utf8.formIndex(after: &index)
            segmentStart = index
            continue
        }
        if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
            flush(upTo: index)
            utf8.formIndex(after: &index)
            if byte == UInt8(ascii: "\r"),
               index < utf8.endIndex,
               utf8[index] == UInt8(ascii: "\n")
            {
                utf8.formIndex(after: &index)
            }
            segmentStart = index
            continue
        }
        index = nextScalarIndex(utf8, index)
    }
    flush(upTo: utf8.endIndex)
    return segments
}
