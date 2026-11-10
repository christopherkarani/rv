/// Whether `pattern` matches a command separator literally: an unescaped `;`
/// or `&`, an escaped `\|`, `\;`, `\&`, or a newline (`\n` or a raw one),
/// outside any character class. Alternation `|` and class members such as
/// `[^|;&]` do not count. Nested ICU sets (`[^[:alnum:]_-]`) are tracked by
/// depth.
func patternNamesSegmentSeparator(_ pattern: String) -> Bool {
    var classDepth = 0
    var iterator = pattern.unicodeScalars.makeIterator()
    while let scalar = iterator.next() {
        if scalar == "\\" {
            guard let escaped = iterator.next() else { return false }
            if classDepth == 0, "|;&n".unicodeScalars.contains(escaped) {
                return true
            }
            continue
        }
        switch scalar {
        case "[":
            classDepth += 1
        case "]" where classDepth > 0:
            classDepth -= 1
        case ";", "&", "\n":
            if classDepth == 0 { return true }
        default:
            break
        }
    }
    return false
}
