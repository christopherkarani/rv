import Foundation

enum LiteralMaskLanguage {
    case python
    case node
    case ruby
}

/// `code` with string-literal contents and comments blanked to spaces, same
/// length and offsets, delimiters kept. Only for scans that look for a bare
/// IDENTIFIER (`open` aliasing, mutator names, paren-less `open word`): prose
/// inside a string such as "Could not open file" is not a call. Scans that
/// need the string contents (module names, bracket access, literal paths)
/// must keep reading the original.
///
/// Fails closed: when a literal can carry code (python f-strings, `#{}` or
/// `${}` interpolation), or the scan ends inside an open string or block
/// comment, the original text is returned and nothing is hidden.
func maskingLiteralsAndComments(_ code: String, language: LiteralMaskLanguage) -> String {
    let units = Array(code.utf16)
    var out = units
    let blank: UInt16 = 32
    func at(_ index: Int) -> UInt16? { index < units.count ? units[index] : nil }
    func unit(_ char: Character) -> UInt16 { char.utf16.first ?? 0 }
    var index = 0
    while index < units.count {
        let current = units[index]
        if language == .node, current == unit("/"), at(index + 1) == unit("/") {
            while index < units.count, units[index] != unit("\n") { out[index] = blank; index += 1 }
            continue
        }
        if language == .node, current == unit("/"), at(index + 1) == unit("*") {
            let start = index
            index += 2
            while index < units.count, !(units[index] == unit("*") && at(index + 1) == unit("/")) { index += 1 }
            guard index < units.count else { return code }
            index += 2
            for position in start..<index { out[position] = blank }
            continue
        }
        if language != .node, current == unit("#") {
            while index < units.count, units[index] != unit("\n") { out[index] = blank; index += 1 }
            continue
        }
        guard current == unit("'") || current == unit("\"") || (language == .node && current == unit("`")) else {
            index += 1
            continue
        }
        // A python string prefix (`f"..."`, `rf'...'`) may be an f-string.
        if language == .python, index > 0, hasFStringPrefix(units, before: index) { return code }
        let quote = current
        let triple = language == .python && at(index + 1) == quote && at(index + 2) == quote
        index += triple ? 3 : 1
        let contentStart = index
        var closed = false
        while index < units.count {
            let char = units[index]
            if char == unit("\\") {
                index += 2
                continue
            }
            if triple {
                if char == quote, at(index + 1) == quote, at(index + 2) == quote { closed = true; break }
            } else if char == quote {
                closed = true
                break
            }
            if language == .ruby, quote == unit("\""), char == unit("#"), at(index + 1) == unit("{") { return code }
            if language == .node, quote == unit("`"), char == unit("$"), at(index + 1) == unit("{") { return code }
            index += 1
        }
        guard closed else { return code }
        let contentEnd = min(index, units.count)
        for position in contentStart..<contentEnd where out[position] != unit("\n") { out[position] = blank }
        index += triple ? 3 : 1
    }
    return String(decoding: out, as: UTF16.self)
}

private func hasFStringPrefix(_ units: [UInt16], before quote: Int) -> Bool {
    var position = quote - 1
    var seen = 0
    while position >= 0, seen < 2 {
        guard let scalar = UnicodeScalar(units[position]), scalar.isASCII, Character(scalar).isLetter else { break }
        if Character(scalar) == "f" || Character(scalar) == "F" { return true }
        position -= 1
        seen += 1
    }
    return false
}
