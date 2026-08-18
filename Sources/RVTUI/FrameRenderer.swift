import RVTheme

public protocol FrameRenderer<Model>: Sendable {
    associatedtype Model
    func render(_ model: Model, palette: Palette) -> [String]
}

func paint(_ text: String, slot: String, reset: String) -> String {
    if slot.isEmpty { return text }
    return slot + text + reset
}

func padRight(_ text: String, to width: Int) -> String {
    if text.count >= width { return text }
    return text + String(repeating: " ", count: width - text.count)
}

func wrapLine(_ line: String, width: Int = 80) -> [String] {
    if line.isEmpty { return [""] }
    if line.count <= width { return [line] }
    var lines: [String] = []
    var rest = line
    while rest.count > width {
        let idx = rest.index(rest.startIndex, offsetBy: width)
        var cut = idx
        if let space = rest[..<idx].lastIndex(of: " ") {
            cut = space
        }
        lines.append(String(rest[..<cut]))
        rest = String(rest[cut...].drop(while: \.isWhitespace))
    }
    if !rest.isEmpty {
        lines.append(rest)
    }
    return lines
}
