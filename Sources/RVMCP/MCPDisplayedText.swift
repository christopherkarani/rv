/// Text a person reads in a terminal before they approve. Control characters
/// stay inside the field, so a value cannot redraw the screen or start a line.
/// A literal backslash is doubled before a control is written as `\n` or
/// `\uXXXX`, so the escape text is not the same field as the control.
public enum MCPDisplayedText {
    public static func field(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            if scalar.value == 0x5C {
                escaped += "\\\\"
                continue
            }
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
            case 0x98: escaped += "\\u0098"
            case 0x9B: escaped += "\\u009b"
            case 0x9C: escaped += "\\u009c"
            case 0x9D: escaped += "\\u009d"
            case 0x9E: escaped += "\\u009e"
            case 0x9F: escaped += "\\u009f"
            case 0x2028: escaped += "\\u2028"
            case 0x2029: escaped += "\\u2029"
            case 0x202A: escaped += "\\u202a"
            case 0x202B: escaped += "\\u202b"
            case 0x202C: escaped += "\\u202c"
            case 0x202D: escaped += "\\u202d"
            case 0x202E: escaped += "\\u202e"
            case 0x2066: escaped += "\\u2066"
            case 0x2067: escaped += "\\u2067"
            case 0x2068: escaped += "\\u2068"
            case 0x2069: escaped += "\\u2069"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}
