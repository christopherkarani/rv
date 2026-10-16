import RVDomain

/// Text a person reads in a terminal before they approve. Control characters
/// stay inside the field, so a value cannot redraw the screen or start a line.
/// A literal backslash is doubled before a control is written as `\n` or
/// `\uXXXX`, so the escape text is not the same field as the control.
public enum MCPDisplayedText {
    public static func field(_ text: String) -> String {
        DisplayedText.field(text)
    }
}
