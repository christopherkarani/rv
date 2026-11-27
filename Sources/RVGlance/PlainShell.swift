import Foundation

/// Shell text as the plain line may use it. Comments carry no effect and
/// are the easiest place for an agent to plant words aimed at the
/// explainer (`rm -rf ~ # Would list files here`), so they are removed
/// before the template reads the command or the model sees it.
public enum PlainShell {
    /// `command` without `#` comments: a `#` that starts a word outside
    /// quotes runs to the end of its line. Quoted and escaped `#` stay.
    public static func strippingComments(_ command: String) -> String {
        var out = ""
        var quote: Character?
        var escaped = false
        var inComment = false
        var previous: Character = " "
        for char in command {
            if inComment {
                if char == "\n" {
                    inComment = false
                    out.append(char)
                    previous = char
                }
                continue
            }
            defer { previous = char }
            if escaped {
                escaped = false
                out.append(char)
                continue
            }
            if char == "\\", quote != "'" {
                escaped = true
                out.append(char)
                continue
            }
            if let open = quote {
                if char == open { quote = nil }
                out.append(char)
                continue
            }
            if char == "'" || char == "\"" {
                quote = char
                out.append(char)
                continue
            }
            if char == "#", previous.isWhitespace || ";&|(".contains(previous) {
                inComment = true
                continue
            }
            out.append(char)
        }
        return out.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
