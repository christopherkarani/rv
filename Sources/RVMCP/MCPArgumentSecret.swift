/// How a local server's `args` would put a secret in its command line,
/// where `ps` shows it to every user (`MCPLaunchPlanner.argumentSecret`).
public enum MCPArgumentSecret: Sendable, Equatable {
    /// `${secret:NAME}` in an arg.
    case reference(String)
    /// `$VAR` or `${VAR}` in an arg, for `variable` in the server's
    /// `secrets` (bound to rv secret `secret`). A shell or launcher that
    /// expands it puts the value in its child's arguments.
    case expanded(variable: String, secret: String)

    /// What is wrong, short enough for `rv mcp list`.
    public var reason: String {
        switch self {
        case .reference(let secret):
            "secret \(MCPDisplayedText.field(secret)) is in its args, where ps shows it"
        case .expanded(let variable, let secret):
            "its args expand $\(MCPDisplayedText.field(variable)) (secret \(MCPDisplayedText.field(secret))) "
                + "into a command line, where ps shows it"
        }
    }

    /// The one fix: the server reads the secret from its environment.
    public var fix: String {
        switch self {
        case .reference(let secret):
            let name = MCPDisplayedText.field(secret)
            return "remove ${secret:\(name)} from args and add \"secrets\": {\"\(name)\": \"\(name)\"} "
                + "so the server reads $\(name), then rv mcp trust"
        case .expanded(let variable, _):
            let name = MCPDisplayedText.field(variable)
            return "remove $\(name) from args so the server reads $\(name) from its environment itself, then rv mcp trust"
        }
    }

    /// The variable names `arg` expands the way a POSIX shell would: `$NAME`
    /// and `${NAME…}` (any `${NAME:-x}` form included). `$$`, `$1` and a
    /// bare `$` name no variable.
    public static func expandedVariables(in arg: String) -> [String] {
        let scalars = Array(arg.unicodeScalars)
        func isHead(_ c: Unicode.Scalar) -> Bool { c == "_" || ("A"..."Z").contains(c) || ("a"..."z").contains(c) }
        func isBody(_ c: Unicode.Scalar) -> Bool { isHead(c) || ("0"..."9").contains(c) }
        var names: [String] = []
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "$" else {
                index += 1
                continue
            }
            var start = index + 1
            if start < scalars.count, scalars[start] == "{" { start += 1 }
            var end = start
            if end < scalars.count, isHead(scalars[end]) {
                end += 1
                while end < scalars.count, isBody(scalars[end]) { end += 1 }
                var name = String.UnicodeScalarView()
                name.append(contentsOf: scalars[start..<end])
                names.append(String(name))
            }
            index = max(end, index + 1)
        }
        return names
    }
}
