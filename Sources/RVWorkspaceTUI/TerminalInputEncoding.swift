import Foundation

/// Input modes are read from the focused pane's SwiftTerm emulator after output is parsed.
public struct TerminalInputModes: Equatable, Sendable {
    public var applicationCursor: Bool
    public var bracketedPaste: Bool

    public init(applicationCursor: Bool = false, bracketedPaste: Bool = false) {
        self.applicationCursor = applicationCursor
        self.bracketedPaste = bracketedPaste
    }
}

public enum TerminalInputEncoding {
    public static func bytes(for key: TUIKey, modes: TerminalInputModes) -> Data {
        switch key {
        case .arrow(let direction):
            let final = arrowFinal(direction)
            return Data("\u{1b}\(modes.applicationCursor ? "O" : "[")\(final)".utf8)
        case .home:
            return Data("\u{1b}\(modes.applicationCursor ? "O" : "[")H".utf8)
        case .end:
            return Data("\u{1b}\(modes.applicationCursor ? "O" : "[")F".utf8)
        case .alt(.arrow(let direction)):
            return Data("\u{1b}[1;3\(arrowFinal(direction))".utf8)
        case .alt(.home):
            return Data("\u{1b}[1;3H".utf8)
        case .alt(.end):
            return Data("\u{1b}[1;3F".utf8)
        default:
            return TerminalInputEncoder.bytes(for: key)
        }
    }

    /// The caller sends this byte stream through its existing input lease.
    /// The session transport chunks it at protocol frame boundaries.
    public static func paste(_ content: String, modes: TerminalInputModes) -> Data {
        guard modes.bracketedPaste else { return Data(content.utf8) }
        return Data("\u{1b}[200~\(content)\u{1b}[201~".utf8)
    }

    private static func arrowFinal(_ direction: FocusDirection) -> Character {
        switch direction {
        case .up: "A"
        case .down: "B"
        case .right: "C"
        case .left: "D"
        }
    }
}
