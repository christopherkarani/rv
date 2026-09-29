/// Unquoted `\n` / `\r\n` / `\r` width. Quoted newlines stay inside the token.
func newlineWidth(_ utf8: String.UTF8View, at index: String.Index) -> Int? {
    guard index < utf8.endIndex else { return nil }
    let byte = utf8[index]
    if byte == UInt8(ascii: "\n") { return 1 }
    if byte == UInt8(ascii: "\r") {
        let next = utf8.index(after: index)
        if next < utf8.endIndex, utf8[next] == UInt8(ascii: "\n") {
            return 2
        }
        return 1
    }
    return nil
}

func whitespaceLength(_ utf8: String.UTF8View, at index: String.Index) -> Int {
    let byte = utf8[index]
    if byte < 0x80 {
        switch byte {
        case 9, 10, 11, 12, 13, 32:
            return 1
        default:
            return 0
        }
    }
    guard let (scalar, width) = decodeScalar(utf8, at: index) else { return 0 }
    return Character(scalar).isWhitespace ? width : 0
}

func nextScalarIndex(_ utf8: String.UTF8View, _ index: String.Index) -> String.Index {
    if utf8[index] < 0x80 {
        return utf8.index(after: index)
    }
    guard let (_, width) = decodeScalar(utf8, at: index) else {
        return utf8.index(after: index)
    }
    return utf8.index(index, offsetBy: width, limitedBy: utf8.endIndex) ?? utf8.endIndex
}

private func decodeScalar(
    _ utf8: String.UTF8View,
    at index: String.Index
) -> (Unicode.Scalar, Int)? {
    var iterator = utf8[index...].makeIterator()
    var decoder = UTF8()
    switch decoder.decode(&iterator) {
    case .scalarValue(let scalar):
        return (scalar, utf8Width(scalar))
    case .emptyInput, .error:
        return nil
    }
}

private func utf8Width(_ scalar: Unicode.Scalar) -> Int {
    switch scalar.value {
    case 0..<0x80:
        return 1
    case 0x80..<0x800:
        return 2
    case 0x800..<0x1_0000:
        return 3
    default:
        return 4
    }
}
