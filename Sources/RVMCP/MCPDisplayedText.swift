/// Text a person reads in a terminal before they approve. Control characters
/// stay inside the field, so a value cannot redraw the screen or start a line.
public enum MCPDisplayedText {
    public static func field(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x08: escaped += "\\u0008"
            case 0x0A: escaped += "\\n"
            case 0x0B: escaped += "\\u000b"
            case 0x0C: escaped += "\\u000c"
            case 0x0D: escaped += "\\r"
            case 0x1B: escaped += "\\u001b"
            case 0x84: escaped += "\\u0084"
            case 0x85: escaped += "\\u0085"
            case 0x8D: escaped += "\\u008d"
            case 0x90: escaped += "\\u0090"
            case 0x9B: escaped += "\\u009b"
            case 0x9D: escaped += "\\u009d"
            case 0x2028: escaped += "\\u2028"
            case 0x2029: escaped += "\\u2029"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}
